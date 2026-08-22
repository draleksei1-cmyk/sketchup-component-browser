require 'json'
require 'fileutils'
require 'securerandom'
require 'tempfile'
require 'time'
require 'digest'

require_relative 'fs'
require_relative 'compat'

module Drale
  module ComponentLibraryBrowser
    class Storage
      FORMAT_V3 = 3
      FORMAT_V4 = 4
      INDEX_VERSION = FORMAT_V3
      UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze
      TRANSACTION_VERSION = 2
      DELETE_JOURNAL_VERSION = 1
      TRANSACTION_OPERATIONS = %w[replace delete].freeze
      TRANSACTION_STATES = %w[prepared payload_backed_up payload_staged payload_committed manifest_committed catalog_committed payload_quarantined].freeze
      TRANSACTION_PAYLOADS = %w[model.skp preview.png asset.json].freeze

      attr_reader :lib_root

      def initialize(lib_root)
        raise ArgumentError, 'Library path is empty.' if lib_root.to_s.strip.empty?

        @lib_root = File.expand_path(lib_root)
        @recovery_status = { 'transactions' => [] }
        @format = detect_format
        if @format == :v4
          recover_pending_transactions!
          recover_pending_deletes!
        end
        FS.ensure_library_structure(@lib_root) unless @format == :v4 || @format == :legacy_read_only
        @index = load_or_initialize_index
      end

      def index
        deep_copy(@index)
      end

      def legacy_read_only?
        @format == :legacy_read_only
      end

      def recovery_status
        deep_copy(@recovery_status)
      end

      # Protocol seam for v4 writers. Task 4 will call this instead of making
      # payload, manifest, and catalog changes independently.
      def replace_v4_asset_payloads!(item_id, payloads)
        raise ArgumentError, 'v4 payload replacement requires a v4 library.' unless @format == :v4
        payloads = payloads.is_a?(Hash) ? payloads : {}
        required = %w[model.skp preview.png asset.json]
        raise ArgumentError, 'Replacement payload is incomplete.' unless required.all? { |name| payloads.key?(name) }

        with_transaction!(operation: 'replace', item_id: item_id) do |transaction|
          backup_transaction_payloads!(transaction)
          stage_transaction_payloads!(transaction, payloads)
          commit_transaction_payloads!(transaction)
          commit_transaction_manifest!(transaction)
          assets, = load_v4_assets
          current_catalog = read_v4_catalog
          commit_transaction_catalog!(transaction, v4_catalog_for_assets(assets, current_catalog, extra_categories: v4_extra_categories(current_catalog)))
        end
        reload_index!
      end

      def with_transaction!(operation:, item_id:)
        transaction = prepare_transaction!(operation: operation, item_id: item_id)
        yield transaction
        cleanup_committed_transaction!(transaction) if transaction['state'] == 'catalog_committed'
        true
      rescue StandardError
        recover_transaction_file!(transaction['journal_path']) if defined?(transaction) && transaction
        raise
      end

      def reload_index!
        @index = load_or_initialize_index
        deep_copy(@index)
      end

      def item_by_id(item_id)
        @index['items'].find { |item| item['id'] == item_id.to_s }
      end

      def all_tags
        @index['items'].flat_map { |item| item['tags'] || [] }
              .map(&:to_s)
              .reject(&:empty?)
              .uniq
              .sort
      end

      def add_category!(name)
        return v4_add_category!(name) if @format == :v4
        ensure_legacy_mutation!
        category = FS.normalize_category_name(name)
        return false if @index['categories'].any? { |c| FS.same_name?(c, category) }

        FileUtils.mkdir_p(FS.category_dir(@lib_root, category))
        @index['categories'] << category
        @index['categories'].sort!
        persist_index!
        true
      end

      def rename_category!(old_name, new_name)
        return v4_rename_category!(old_name, new_name) if @format == :v4
        ensure_legacy_mutation!
        old_name = old_name.to_s
        new_name = FS.normalize_category_name(new_name)
        raise ArgumentError, 'Category not found.' unless category_exists?(old_name)
        raise ArgumentError, 'Category already exists.' if category_exists?(new_name)

        old_dir = category_path(old_name)
        new_dir = category_path(new_name)

        FileUtils.mkdir_p(FS.categories_root(@lib_root))
        if File.directory?(old_dir)
          FileUtils.mv(old_dir, new_dir)
        else
          FileUtils.mkdir_p(new_dir)
        end

        @index['items'].each do |item|
          next unless FS.same_name?(item['category'], old_name)

          item['category'] = new_name
          item['skp_rel_path'] = item['skp_rel_path'].sub(/\Acategories\/#{Regexp.escape(old_name)}\//, "categories/#{new_name}/")
          if item['thumb_rel_path'].to_s.start_with?("categories/#{old_name}/")
            item['thumb_rel_path'] = item['thumb_rel_path'].sub(/\Acategories\/#{Regexp.escape(old_name)}\//, "categories/#{new_name}/")
          end
          item['updated_at'] = FS.now_iso8601
        end

        @index['categories'].map! { |category| FS.same_name?(category, old_name) ? new_name : category }
        @index['categories'].uniq!
        @index['categories'].sort!
        persist_index!
        true
      end

      def delete_category!(name)
        return v4_delete_category!(name) if @format == :v4
        ensure_legacy_mutation!
        name = name.to_s
        raise ArgumentError, 'Category not found.' unless category_exists?(name)

        used = @index['items'].any? { |item| FS.same_name?(item['category'], name) }
        raise ArgumentError, 'Category is not empty.' if used

        dir = category_path(name)
        Dir.rmdir(dir) if File.directory?(dir) && Dir.empty?(dir)

        @index['categories'].reject! { |category| FS.same_name?(category, name) }
        persist_index!
        true
      end

      def toggle_favorite!(item_id, value)
        return v4_update_manifest_item!(item_id) { |item| item['favorite'] = !!value } if @format == :v4
        item = require_item!(item_id)
        item['favorite'] = !!value
        item['updated_at'] = FS.now_iso8601
        persist_index!
        item
      end

      def update_item_metadata!(item_id, attrs = {})
        if @format == :v4
          attrs = {} unless attrs.is_a?(Hash)
          return v4_update_manifest_item!(item_id) do |item|
            item['file_size_bytes'] = normalize_integer(attrs['file_size_bytes'])
            item['bbox_xyz'] = normalize_bbox(attrs['bbox_xyz'])
            item['faces_count'] = normalize_integer(attrs['faces_count'])
            item['edges_count'] = normalize_integer(attrs['edges_count'])
            item['materials_count'] = normalize_integer(attrs['materials_count'])
          end
        end
        item = require_item!(item_id)
        attrs = {} unless attrs.is_a?(Hash)

        item['file_size_bytes'] = normalize_integer(attrs['file_size_bytes'])
        item['bbox_xyz'] = normalize_bbox(attrs['bbox_xyz'])
        item['faces_count'] = normalize_integer(attrs['faces_count'])
        item['edges_count'] = normalize_integer(attrs['edges_count'])
        item['materials_count'] = normalize_integer(attrs['materials_count'])
        item['updated_at'] = FS.now_iso8601
        persist_index!
        item
      end

      def set_content_hash!(item_id, hash_value)
        return v4_update_manifest_item!(item_id) { |item| item['content_hash'] = normalize_hash(hash_value) } if @format == :v4
        item = require_item!(item_id)
        item['content_hash'] = normalize_hash(hash_value)
        item['updated_at'] = FS.now_iso8601
        persist_index!
        item
      end

      # Сохраняет паспорт размещения элемента (оба формата хранилища).
      def update_item_placement!(item_id, placement)
        normalized = Services::Placement.normalize(placement)
        if @format == :v4
          updated = v4_update_manifest_item!(item_id) { |manifest| manifest['placement'] = normalized }
          return updated
        end

        ensure_legacy_mutation!
        item = require_item!(item_id)
        item['placement'] = normalized
        item['updated_at'] = FS.now_iso8601
        persist_index!
        item
      end

      def replace_item_definition!(item_id, definition, source:, metadata: nil, content_hash: nil)
        raise ArgumentError, 'Definition is required.' unless definition
        return v4_replace_item_definition!(item_id, definition, source: source, metadata: metadata, content_hash: content_hash) if @format == :v4

        item = require_item!(item_id)
        item_snapshot = deep_copy(item)
        skp_path = FS.to_full_path(@lib_root, item['skp_rel_path'])
        raise ArgumentError, "File not found: #{skp_path}" unless File.file?(skp_path)

        tmp_skp = "#{skp_path}.tmp.skp"
        backup_skp = "#{skp_path}.bak.replace"
        saved = Compat.save_definition_to_file(
          definition,
          tmp_skp,
          purpose: :library_replace,
          library_path: @lib_root
        )
        raise 'Не удалось сохранить временный файл замены.' unless saved && File.file?(tmp_skp)

        FileUtils.mv(skp_path, backup_skp, force: true)
        FileUtils.mv(tmp_skp, skp_path, force: true)

        normalized_meta = normalize_item_metadata_hash(metadata)
        normalized_meta['file_size_bytes'] ||= normalize_integer(File.size(skp_path)) if File.file?(skp_path)
        normalized_meta['bbox_xyz'] ||= normalize_bbox([definition.bounds.width.to_f, definition.bounds.depth.to_f, definition.bounds.height.to_f])

        item['source'] = source.to_s.empty? ? item['source'] : source.to_s
        item['file_size_bytes'] = normalized_meta['file_size_bytes']
        item['bbox_xyz'] = normalized_meta['bbox_xyz']
        item['faces_count'] = normalized_meta['faces_count']
        item['edges_count'] = normalized_meta['edges_count']
        item['materials_count'] = normalized_meta['materials_count']
        item['content_hash'] = normalize_hash(content_hash)
        item['updated_at'] = FS.now_iso8601

        persist_index!
        File.delete(backup_skp) if File.file?(backup_skp)
        item
      rescue StandardError
        begin
          if defined?(backup_skp) && backup_skp && File.file?(backup_skp)
            FileUtils.mv(backup_skp, skp_path, force: true)
          end
        rescue StandardError
          # ignore rollback failures
        end
        if defined?(item_snapshot) && item_snapshot.is_a?(Hash) && item.is_a?(Hash)
          item.clear
          item.merge!(item_snapshot)
        end
        raise
      ensure
        File.delete(tmp_skp) if defined?(tmp_skp) && tmp_skp && File.file?(tmp_skp)
        File.delete(backup_skp) if defined?(backup_skp) && backup_skp && File.file?(backup_skp)
      end

      def touch_last_used!(item_id)
        if @format == :v4
          now = FS.now_iso8601
          v4_update_manifest_item!(item_id, now) { |item| item['last_used_at'] = now }
          return nil
        end
        item = require_item!(item_id)
        now = FS.now_iso8601
        item['last_used_at'] = now
        item['updated_at'] = now
        persist_index!
      end

      def delete_item!(item_id)
        return v4_delete_item!(item_id) if @format == :v4
        item = require_item!(item_id)

        [item['skp_rel_path'], item['thumb_rel_path']].each do |rel|
          path = FS.to_full_path(@lib_root, rel)
          File.delete(path) if File.file?(path)
        end

        @index['items'].reject! { |entry| entry['id'] == item['id'] }
        persist_index!
        true
      end

      def save_definition!(definition, source:, category:, display_name:, tags:, metadata: nil, content_hash: nil, description: nil)
        return v4_save_definition!(definition, source: source, category: category, display_name: display_name, tags: tags, metadata: metadata, content_hash: content_hash, description: description) if @format == :v4
        ensure_legacy_mutation!
        category = ensure_category!(category)
        requested_name = FS.normalize_display_name(display_name)
        taken_names = @index['items'].select { |item| FS.same_name?(item['category'], category) }.map { |item| item['name'] }
        final_name = FS.next_unique_name(requested_name, taken_names)
        name_changed = !FS.same_name?(requested_name, final_name)
        item_id = SecureRandom.uuid

        short_id = FS.short_id
        target = build_target_paths(category, final_name, short_id, item_id: item_id)

        while File.exist?(target[:skp_full_path]) || File.exist?(target[:png_full_path])
          short_id = FS.short_id
          target = build_target_paths(category, final_name, short_id, item_id: item_id)
        end

        FileUtils.mkdir_p(File.dirname(target[:skp_full_path]))
        saved = Compat.save_definition_to_file(
          definition,
          target[:skp_full_path],
          purpose: :library_save,
          library_path: @lib_root
        )
        raise 'Не удалось сохранить компонент в библиотеку.' unless saved
        definition.save_thumbnail(target[:png_full_path])
        FS.compact_png_thumbnail(target[:png_full_path], 256)

        now = FS.now_iso8601
        normalized_meta = normalize_item_metadata_hash(metadata)
        normalized_meta['file_size_bytes'] ||= normalize_integer(File.size(target[:skp_full_path])) if File.file?(target[:skp_full_path])
        normalized_meta['bbox_xyz'] ||= normalize_bbox([definition.bounds.width.to_f, definition.bounds.depth.to_f, definition.bounds.height.to_f])
        item = {
          'id' => item_id,
          'name' => final_name,
          'category' => category,
          'description' => normalize_description(description),
          'tags' => FS.normalize_tags(tags),
          'favorite' => false,
          'created_at' => now,
          'updated_at' => now,
          'last_used_at' => nil,
          'skp_rel_path' => target[:skp_rel_path],
          'thumb_rel_path' => target[:png_rel_path],
          'source' => source.to_s,
          'file_size_bytes' => normalized_meta['file_size_bytes'],
          'bbox_xyz' => normalized_meta['bbox_xyz'],
          'faces_count' => normalized_meta['faces_count'],
          'edges_count' => normalized_meta['edges_count'],
          'materials_count' => normalized_meta['materials_count'],
          'content_hash' => normalize_hash(content_hash),
          'placement' => Services::Placement.normalize(nil)
        }

        @index['items'] << item
        persist_index!
        { 'item' => item, 'name_changed' => name_changed, 'requested_name' => requested_name, 'final_name' => final_name }
      end

      def edit_item!(item_id, attrs)
        return v4_edit_item!(item_id, attrs) if @format == :v4
        item = require_item!(item_id)
        requested_name = FS.normalize_display_name(attrs['name'] || item['name'])
        requested_category = ensure_category!(attrs['category'] || item['category'])
        requested_description = normalize_description(attrs.key?('description') ? attrs['description'] : item['description'])
        requested_tags = FS.normalize_tags(attrs['tags'] || item['tags'] || [])

        short_id = FS.extract_short_id(File.basename(item['skp_rel_path'])) || FS.short_id
        taken_names = @index['items'].reject { |entry| entry['id'] == item['id'] }
                                    .select { |entry| FS.same_name?(entry['category'], requested_category) }
                                    .map { |entry| entry['name'] }

        final_name = FS.next_unique_name(requested_name, taken_names)
        target = build_target_paths(requested_category, final_name, short_id, item_id: item['id'])
        old_skp = FS.to_full_path(@lib_root, item['skp_rel_path'])
        old_png = FS.to_full_path(@lib_root, item['thumb_rel_path'])

        move_file(old_skp, target[:skp_full_path]) unless same_path?(old_skp, target[:skp_full_path])
        move_file(old_png, target[:png_full_path]) if File.file?(old_png) && !same_path?(old_png, target[:png_full_path])

        item['name'] = final_name
        item['category'] = requested_category
        item['description'] = requested_description
        item['tags'] = requested_tags
        item['skp_rel_path'] = target[:skp_rel_path]
        item['thumb_rel_path'] = target[:png_rel_path]
        item['updated_at'] = FS.now_iso8601

        persist_index!
        { 'item' => item, 'name_changed' => !FS.same_name?(requested_name, final_name), 'requested_name' => requested_name, 'final_name' => final_name }
      end

      def scan_library!
        return v4_scan_library! if @format == :v4
        ensure_legacy_mutation!
        categories_root = FS.categories_root(@lib_root)
        previews_root = FS.previews_root(@lib_root)
        FileUtils.mkdir_p(categories_root)
        FileUtils.mkdir_p(previews_root)

        existing = @index['items'].each_with_object({}) do |item, map|
          map[item['skp_rel_path']] = item
        end

        scanned_items = []
        scanned_categories = []

        Dir.glob(File.join(categories_root, '*')).sort.each do |category_dir|
          next unless File.directory?(category_dir)

          category = File.basename(category_dir)
          scanned_categories << category

          Dir.glob(File.join(category_dir, '*.skp')).sort.each do |skp_path|
            filename = File.basename(skp_path)
            skp_rel = FS.to_rel_path(@lib_root, skp_path)
            existing_item = existing[skp_rel]
            item_id = existing_item ? existing_item['id'] : SecureRandom.uuid
            png_filename = "#{item_id}.png"
            png_path = File.join(previews_root, png_filename)

            # Backward compatibility: if old preview exists near skp, copy it once.
            if !File.file?(png_path)
              legacy_base = File.basename(filename, '.skp')
              legacy_png = File.join(category_dir, "#{legacy_base}.png")
              FileUtils.cp(legacy_png, png_path) if File.file?(legacy_png)
            end

            yield(skp_path, png_path) if !File.file?(png_path) && block_given?

            png_rel = FS.to_rel_path(@lib_root, png_path)
            now = FS.now_iso8601
            source = existing_item && existing_item['source'] ? existing_item['source'] : 'component'

            item = {
              'id' => item_id,
              'name' => existing_item ? existing_item['name'] : FS.display_name_from_skp(filename),
              'category' => category,
              'description' => existing_item ? normalize_description(existing_item['description']) : '',
              'tags' => existing_item ? FS.normalize_tags(existing_item['tags']) : [],
              'favorite' => existing_item ? !!existing_item['favorite'] : false,
              'created_at' => existing_item ? existing_item['created_at'] : now,
              'updated_at' => now,
              'last_used_at' => existing_item ? existing_item['last_used_at'] : nil,
              'skp_rel_path' => skp_rel,
              'thumb_rel_path' => png_rel,
              'source' => source,
              'file_size_bytes' => existing_item ? normalize_integer(existing_item['file_size_bytes']) : normalize_integer(File.size(skp_path)),
              'bbox_xyz' => existing_item ? normalize_bbox(existing_item['bbox_xyz']) : nil,
              'faces_count' => existing_item ? normalize_integer(existing_item['faces_count']) : nil,
              'edges_count' => existing_item ? normalize_integer(existing_item['edges_count']) : nil,
              'materials_count' => existing_item ? normalize_integer(existing_item['materials_count']) : nil,
              'content_hash' => existing_item ? normalize_hash(existing_item['content_hash']) : nil,
              'placement' => Services::Placement.normalize(existing_item ? existing_item['placement'] : nil)
            }

            scanned_items << item
          end
        end

        @index['items'] = scanned_items
        @index['categories'] = scanned_categories.sort
        persist_index!
        scanned_items.length
      end

      private

      # V4 keeps each asset self-contained.  The catalog is only a directory of
      # asset folders plus explicitly-created empty categories; it never owns
      # item metadata or file paths.
      def v4_save_definition!(definition, source:, category:, display_name:, tags:, metadata:, content_hash:, description:)
        raise ArgumentError, 'Definition is required.' unless definition

        category = FS.normalize_category_name(category)
        requested_name = FS.normalize_display_name(display_name)
        taken = @index['items'].select { |entry| FS.same_name?(entry['category'], category) }.map { |entry| entry['name'] }
        final_name = FS.next_unique_name(requested_name, taken)
        item_id = SecureRandom.uuid
        FileUtils.mkdir_p(FS.assets_root(@lib_root))
        model_path = v4_payload_path(item_id, 'model.skp')
        saved = Compat.save_definition_to_file(definition, model_path, purpose: :library_save, library_path: @lib_root)
        raise 'Не удалось сохранить компонент в библиотеку.' unless saved && File.file?(model_path)

        preview_path = v4_payload_path(item_id, 'preview.png')
        begin
          definition.save_thumbnail(preview_path) if definition.respond_to?(:save_thumbnail)
          FS.compact_png_thumbnail(preview_path, 256) if File.file?(preview_path)
        rescue StandardError
          File.delete(preview_path) if File.file?(preview_path)
        end

        now = FS.now_iso8601
        normalized_meta = normalize_item_metadata_hash(metadata)
        normalized_meta['file_size_bytes'] ||= normalize_integer(File.size(model_path))
        normalized_meta['bbox_xyz'] ||= normalize_bbox([definition.bounds.width.to_f, definition.bounds.depth.to_f, definition.bounds.height.to_f]) if definition.respond_to?(:bounds)
        manifest = v4_manifest_from_item({
          'id' => item_id, 'name' => final_name, 'category' => category, 'description' => normalize_description(description),
          'tags' => FS.normalize_tags(tags), 'favorite' => false, 'created_at' => now, 'updated_at' => now,
          'last_used_at' => nil, 'source' => source.to_s, 'content_hash' => normalize_hash(content_hash)
        }.merge(normalized_meta))
        atomic_write_json(v4_payload_path(item_id, 'asset.json'), manifest)
        reload_index!
        persist_v4_catalog!
        item = item_by_id(item_id)
        { 'item' => item, 'name_changed' => !FS.same_name?(requested_name, final_name), 'requested_name' => requested_name, 'final_name' => final_name }
      rescue StandardError
        TRANSACTION_PAYLOADS.each do |name|
          path = v4_payload_path(item_id, name) if defined?(item_id)
          File.delete(path) if defined?(path) && File.file?(path)
        end
        raise
      end

      def v4_edit_item!(item_id, attrs)
        attrs = {} unless attrs.is_a?(Hash)
        item = v4_item!(item_id)
        requested_name = FS.normalize_display_name(attrs['name'] || item['name'])
        category = FS.normalize_category_name(attrs['category'] || item['category'])
        taken = @index['items'].reject { |entry| entry['id'] == item['id'] }
                               .select { |entry| FS.same_name?(entry['category'], category) }.map { |entry| entry['name'] }
        final_name = FS.next_unique_name(requested_name, taken)
        updated = v4_update_manifest_item!(item_id) do |manifest|
          manifest['name'] = final_name
          manifest['category'] = category
          manifest['description'] = normalize_description(attrs.key?('description') ? attrs['description'] : item['description'])
          manifest['tags'] = FS.normalize_tags(attrs.key?('tags') ? attrs['tags'] : item['tags'])
        end
        { 'item' => updated, 'name_changed' => !FS.same_name?(requested_name, final_name), 'requested_name' => requested_name, 'final_name' => final_name }
      end

      def v4_replace_item_definition!(item_id, definition, source:, metadata:, content_hash:)
        item = v4_item!(item_id)
        staged = File.join(FS.assets_root(@lib_root), ".#{item['id']}-model-#{SecureRandom.uuid}.tmp")
        saved = Compat.save_definition_to_file(definition, staged, purpose: :library_replace, library_path: @lib_root)
        raise 'Не удалось сохранить временный файл замены.' unless saved && File.file?(staged)

        supplied_metadata = metadata.is_a?(Hash) ? metadata : {}
        normalized_meta = normalize_item_metadata_hash(supplied_metadata)
        merged_item = item.dup
        normalized_meta.each do |key, value|
          merged_item[key] = value if supplied_metadata.key?(key)
        end
        merged_item['file_size_bytes'] ||= normalize_integer(File.size(staged))
        merged_item['bbox_xyz'] ||= normalize_bbox([definition.bounds.width.to_f, definition.bounds.depth.to_f, definition.bounds.height.to_f]) if definition.respond_to?(:bounds)
        manifest = v4_manifest_from_item(merged_item.merge(
          'source' => source.to_s.empty? ? item['source'] : source.to_s,
          'content_hash' => content_hash.nil? ? item['content_hash'] : normalize_hash(content_hash), 'updated_at' => FS.now_iso8601
        ))
        payloads = {
          'model.skp' => File.binread(staged),
          'preview.png' => File.file?(v4_payload_path(item['id'], 'preview.png')) ? File.binread(v4_payload_path(item['id'], 'preview.png')) : ''.b,
          'asset.json' => JSON.pretty_generate(manifest)
        }
        replace_v4_asset_payloads!(item_id, payloads)
        item_by_id(item_id)
      ensure
        File.delete(staged) if defined?(staged) && staged && File.file?(staged)
      end

      def v4_update_manifest_item!(item_id, now = FS.now_iso8601)
        item = v4_item!(item_id)
        manifest_path = v4_payload_path(item['id'], 'asset.json')
        before = File.binread(manifest_path)
        manifest = v4_manifest_from_item(item)
        yield manifest
        manifest['updated_at'] = now
        atomic_write_json(manifest_path, manifest)
        begin
          reload_index!
          persist_v4_catalog!
        rescue StandardError
          atomic_write_bytes(manifest_path, before)
          reload_index!
          raise
        end
        item_by_id(item_id)
      end

      def v4_delete_item!(item_id)
        item = v4_item!(item_id)
        txid = SecureRandom.uuid
        journal = prepare_delete_journal!(txid, item['id'])
        journal.fetch('payloads').each do |payload|
          name = payload.fetch('name')
          next unless payload['existed']

          source = v4_payload_path(item['id'], name)
          destination = FS.trash_path(@lib_root, txid, File.basename(source))
          FileUtils.mkdir_p(File.dirname(destination))
          File.rename(source, destination)
          journal['phase'] = "#{name.sub(/\..*\z/, '')}_moved"
          persist_delete_journal!(journal)
          test_failure_after!('delete_model_moved') if name == 'model.skp'
        end
        reload_index!
        persist_v4_catalog!
        journal['state'] = 'catalog_committed'
        journal['phase'] = 'complete'
        persist_delete_journal!(journal)
        File.delete(delete_journal_path(txid))
        true
      end

      def v4_add_category!(name)
        category = FS.normalize_category_name(name)
        return false if @index['categories'].any? { |entry| FS.same_name?(entry, category) }

        persist_v4_catalog!(extra_categories: v4_extra_categories + [category])
        reload_index!
        true
      end

      def v4_rename_category!(old_name, new_name)
        old_name = old_name.to_s
        new_name = FS.normalize_category_name(new_name)
        raise ArgumentError, 'Category not found.' unless category_exists?(old_name)
        raise ArgumentError, 'Category already exists.' if category_exists?(new_name)

        @index['items'].select { |item| FS.same_name?(item['category'], old_name) }.each do |item|
          v4_update_manifest_item!(item['id']) { |manifest| manifest['category'] = new_name }
        end
        extras = v4_extra_categories.map { |category| FS.same_name?(category, old_name) ? new_name : category }
        persist_v4_catalog!(extra_categories: extras)
        reload_index!
        true
      end

      def v4_delete_category!(name)
        name = name.to_s
        raise ArgumentError, 'Category not found.' unless category_exists?(name)
        raise ArgumentError, 'Category is not empty.' if @index['items'].any? { |item| FS.same_name?(item['category'], name) }

        persist_v4_catalog!(extra_categories: v4_extra_categories.reject { |category| FS.same_name?(category, name) })
        reload_index!
        true
      end

      def v4_scan_library!
        assets, = load_v4_assets
        persist_v4_catalog!(assets: assets)
        reload_index!
        assets.length
      end

      def v4_item!(item_id)
        item = item_by_id(item_id)
        raise ArgumentError, 'Item not found.' unless item

        item
      end

      def v4_manifest_from_item(item)
        {
          'asset_version' => 1, 'id' => item['id'], 'name' => FS.normalize_display_name(item['name']),
          'category' => FS.normalize_category_name(item['category']), 'description' => normalize_description(item['description']),
          'tags' => FS.normalize_tags(item['tags']), 'favorite' => !!item['favorite'], 'created_at' => item['created_at'],
          'updated_at' => item['updated_at'], 'last_used_at' => item['last_used_at'],
          'source' => item['source'].to_s.empty? ? 'component' : item['source'].to_s,
          'file_size_bytes' => normalize_integer(item['file_size_bytes']), 'bbox_xyz' => normalize_bbox(item['bbox_xyz']),
          'faces_count' => normalize_integer(item['faces_count']), 'edges_count' => normalize_integer(item['edges_count']),
          'materials_count' => normalize_integer(item['materials_count']), 'content_hash' => normalize_hash(item['content_hash']),
          'placement' => Services::Placement.normalize(item['placement'])
        }
      end

      def v4_extra_categories(catalog = read_v4_catalog)
        Array(catalog && catalog['categories']).map { |entry| FS.normalize_category_name(entry) }.uniq.sort
      rescue ArgumentError
        []
      end

      def persist_v4_catalog!(assets: nil, extra_categories: nil)
        assets ||= load_v4_assets.first
        catalog = read_v4_catalog
        extra_categories = v4_extra_categories(catalog) if extra_categories.nil?
        atomic_write_json(FS.catalog_path(@lib_root), v4_catalog_for_assets(assets, catalog, extra_categories: extra_categories))
      end

      def prepare_transaction!(operation:, item_id:)
        raise ArgumentError, 'Invalid transaction operation.' unless TRANSACTION_OPERATIONS.include?(operation.to_s)
        raise ArgumentError, 'Invalid transaction item id.' unless item_id.to_s.match?(UUID_PATTERN)

        txid = SecureRandom.uuid
        FileUtils.mkdir_p(FS.transactions_root(@lib_root))
        FileUtils.mkdir_p(FS.transaction_path(@lib_root, txid))
        catalog_path = FS.catalog_path(@lib_root)
        catalog_existed = File.file?(catalog_path)
        catalog_bytes = catalog_existed ? File.binread(catalog_path) : nil
        payloads = TRANSACTION_PAYLOADS.map do |name|
          path = transaction_payload_path(item_id, name)
          existed = File.file?(path)
          {
            'name' => name,
            'existed' => existed,
            'sha256' => existed ? sha256_file(path) : nil,
            'backup_ready' => false
          }
        end
        now = FS.now_iso8601
        transaction = {
          'version' => TRANSACTION_VERSION,
          'id' => txid,
          'state' => 'prepared',
          'operation' => operation.to_s,
          'item_id' => item_id.to_s,
          'created_at' => now,
          'updated_at' => now,
          'payloads' => payloads,
          'catalog_snapshot' => {
            'existed' => catalog_existed,
            'sha256' => catalog_existed ? Digest::SHA256.hexdigest(catalog_bytes) : nil
          }
        }
        transaction['journal_path'] = transaction_journal_path(txid)
        persist_transaction!(transaction)
        atomic_write_bytes(transaction_snapshot_path(transaction), catalog_bytes || ''.b)
        transaction
      end

      def backup_transaction_payloads!(transaction)
        transaction.fetch('payloads').each do |payload|
          next unless payload['existed']

          source = transaction_payload_path(transaction['item_id'], payload['name'])
          backup = transaction_backup_path(transaction, payload['name'])
          atomic_write_bytes(backup, File.binread(source))
          raise "Backup SHA256 mismatch: #{payload['name']}" unless sha256_file(backup) == payload['sha256']

          payload['backup_ready'] = true
          persist_transaction!(transaction)
          test_failure_after!('backup_model_copied') if payload['name'] == 'model.skp'
        end
        transition_transaction!(transaction, 'payload_backed_up')
      end

      def stage_transaction_payloads!(transaction, payloads)
        transaction.fetch('payloads').each do |payload|
          bytes = payloads.fetch(payload['name'])
          staged_path = transaction_staged_path(transaction, payload['name'])
          atomic_write_bytes(staged_path, bytes)
          raise "Staged payload missing: #{payload['name']}" unless File.file?(staged_path)

          payload['staged_sha256'] = sha256_file(staged_path)
          expected = Digest::SHA256.hexdigest(bytes.to_s.b)
          raise "Staged payload hash mismatch: #{payload['name']}" unless payload['staged_sha256'] == expected
          persist_transaction!(transaction)
          test_failure_after!('model_staged') if payload['name'] == 'model.skp'
        end
        transition_transaction!(transaction, 'payload_staged')
      end

      def commit_transaction_payloads!(transaction)
        transaction.fetch('payloads').reject { |payload| payload['name'] == 'asset.json' }.each do |payload|
          File.rename(transaction_staged_path(transaction, payload['name']), transaction_payload_path(transaction['item_id'], payload['name']))
        end
        transition_transaction!(transaction, 'payload_committed')
      end

      def commit_transaction_manifest!(transaction)
        manifest = transaction.fetch('payloads').find { |payload| payload['name'] == 'asset.json' }
        File.rename(transaction_staged_path(transaction, manifest['name']), transaction_payload_path(transaction['item_id'], manifest['name']))
        transition_transaction!(transaction, 'manifest_committed')
      end

      def commit_transaction_catalog!(transaction, catalog)
        atomic_write_json(FS.catalog_path(@lib_root), catalog)
        test_failure_after!('catalog_replaced')
        transition_transaction!(transaction, 'catalog_committed')
      end

      def v4_catalog_for_assets(assets, existing_catalog, extra_categories: nil)
        now = FS.now_iso8601
        created_at = catalog_created_at(existing_catalog)
        created_at = now if Time.iso8601(created_at) > Time.iso8601(now)
        catalog = { 'version' => FORMAT_V4, 'created_at' => created_at, 'updated_at' => now, 'assets' => v4_catalog_assets(assets) }
        categories = Array(extra_categories).map { |entry| FS.normalize_category_name(entry) }.uniq.sort
        catalog['categories'] = categories unless categories.empty?
        catalog
      end

      def transition_transaction!(transaction, state)
        transaction['state'] = state
        transaction['updated_at'] = FS.now_iso8601
        persist_transaction!(transaction)
      end

      def persist_transaction!(transaction)
        atomic_write_json(transaction.fetch('journal_path'), transaction.reject { |key, _| key == 'journal_path' })
      end

      def recover_pending_transactions!
        root = FS.transactions_root(@lib_root)
        return unless File.directory?(root)

        Dir.glob(File.join(root, '*', 'transaction.json')).sort.each { |journal| recover_transaction_file!(journal, record_recovery: true) }
      end

      def recover_pending_deletes!
        root = FS.trash_root(@lib_root)
        return unless File.directory?(root)

        Dir.glob(File.join(root, '*', 'delete.json')).sort.each do |path|
          journal = JSON.parse(File.read(path, encoding: 'UTF-8'))
          validate_delete_journal!(journal, path)
          if journal['state'] == 'prepared'
            journal.fetch('payloads').each do |payload|
              next unless payload['existed']

              source = v4_payload_path(journal['item_id'], payload['name'])
              destination = FS.trash_path(@lib_root, journal['id'], File.basename(source))
              raise 'Delete recovery is ambiguous.' if File.file?(source) && File.file?(destination)
              raise 'Deleted payload is missing.' unless File.file?(source) || File.file?(destination)

              FileUtils.mkdir_p(File.dirname(source))
              File.rename(destination, source) unless File.file?(source)
            end
          end
          File.delete(path)
          tx_root = FS.trash_path(@lib_root, journal['id'])
          Dir.rmdir(tx_root) if Dir.exist?(tx_root) && Dir.empty?(tx_root)
          @recovery_status['transactions'] << { 'id' => journal['id'], 'operation' => 'delete', 'phase' => journal['phase'] }
        rescue StandardError => error
          @recovery_status['transactions'] << { 'journal_path' => path, 'status' => 'recoverable', 'reason' => "#{error.class}: #{error.message}" }
        end
      end

      def recover_transaction_file!(journal_path, record_recovery: false)
        transaction = JSON.parse(File.read(journal_path, encoding: 'UTF-8'))
        transaction['journal_path'] = journal_path
        validate_transaction!(transaction)
        if transaction['state'] == 'catalog_committed'
          cleanup_committed_transaction!(transaction)
          record_successful_recovery!(transaction) if record_recovery
          return true
        end

        verify_recovery_evidence!(transaction)
        if transaction['state'] == 'prepared'
          cleanup_committed_transaction!(transaction)
          record_successful_recovery!(transaction) if record_recovery
          return true
        end
        transaction.fetch('payloads').each do |payload|
          if payload['existed']
            atomic_write_bytes(transaction_payload_path(transaction['item_id'], payload['name']), File.binread(transaction_backup_path(transaction, payload['name'])))
          elsif File.file?(transaction_payload_path(transaction['item_id'], payload['name']))
            File.delete(transaction_payload_path(transaction['item_id'], payload['name']))
          end
        end
        restore_catalog_snapshot!(transaction)
        cleanup_committed_transaction!(transaction)
        record_successful_recovery!(transaction) if record_recovery
        true
      rescue StandardError => error
        @recovery_status ||= { 'transactions' => [] }
        @recovery_status['transactions'] << {
          'journal_path' => journal_path,
          'status' => 'recoverable',
          'reason' => "#{error.class}: #{error.message}"
        }
        false
      end

      def verify_recovery_evidence!(transaction)
        transaction.fetch('payloads').each do |payload|
          next unless payload['existed'] && payload['backup_ready']

          before_path = transaction_backup_path(transaction, payload['name'])
          raise "Backup missing: #{before_path}" unless File.file?(before_path)
          raise "Backup SHA256 mismatch: #{before_path}" unless sha256_file(before_path) == payload.fetch('sha256')
        end
        return if transaction['state'] == 'prepared'

        transaction.fetch('payloads').each do |payload|
          raise "Backup was not ready: #{payload['name']}" unless !payload['existed'] || payload['backup_ready']
        end
        snapshot = transaction.fetch('catalog_snapshot')
        return unless snapshot['existed']

        path = transaction_snapshot_path(transaction)
        raise "Catalog snapshot missing: #{path}" unless File.file?(path)
        raise "Catalog snapshot SHA256 mismatch: #{path}" unless sha256_file(path) == snapshot['sha256']
      end

      def restore_catalog_snapshot!(transaction)
        snapshot = transaction.fetch('catalog_snapshot')
        if snapshot['existed']
          atomic_write_bytes(FS.catalog_path(@lib_root), File.binread(transaction_snapshot_path(transaction)))
        elsif File.file?(FS.catalog_path(@lib_root))
          File.delete(FS.catalog_path(@lib_root))
        end
      end

      def cleanup_committed_transaction!(transaction)
        TRANSACTION_PAYLOADS.each do |name|
          staged_path = transaction_staged_path(transaction, name)
          File.delete(staged_path) if File.file?(staged_path)
        end
        root = transaction_root_path(transaction)
        FileUtils.rm_rf(root) if File.directory?(root)
        File.delete(transaction['journal_path']) if transaction['journal_path'] && File.file?(transaction['journal_path'])
      end

      def record_successful_recovery!(transaction)
        @recovery_status ||= { 'transactions' => [] }
        @recovery_status['transactions'] << {
          'id' => transaction['id'],
          'operation' => transaction['operation'],
          'phase' => transaction['state']
        }
      end

      def validate_transaction!(transaction)
        raise ArgumentError, 'Invalid transaction schema version.' unless transaction['version'] == TRANSACTION_VERSION
        raise ArgumentError, 'Invalid transaction id.' unless transaction['id'].to_s.match?(UUID_PATTERN)
        raise ArgumentError, 'Invalid transaction item id.' unless transaction['item_id'].to_s.match?(UUID_PATTERN)
        raise ArgumentError, 'Invalid transaction operation.' unless TRANSACTION_OPERATIONS.include?(transaction['operation'])
        raise ArgumentError, 'Invalid transaction state.' unless TRANSACTION_STATES.include?(transaction['state'])
        raise ArgumentError, 'Journal contains a forbidden path field.' if journal_contains_path_field?(transaction.reject { |key, _| key == 'journal_path' })
        raise ArgumentError, 'Journal path does not match transaction id.' unless File.expand_path(transaction['journal_path']) == transaction_journal_path(transaction['id'])

        payloads = transaction['payloads']
        raise ArgumentError, 'Invalid transaction payload list.' unless payloads.is_a?(Array) && payloads.map { |payload| payload['name'] }.sort == TRANSACTION_PAYLOADS.sort
        payloads.each do |payload|
          raise ArgumentError, 'Invalid transaction payload.' unless payload.is_a?(Hash) && [true, false].include?(payload['existed'])
          raise ArgumentError, 'Invalid transaction backup state.' unless payload['backup_ready'].is_a?(TrueClass) || payload['backup_ready'].is_a?(FalseClass)
          next unless payload['existed']

          raise ArgumentError, 'Invalid transaction payload hash.' unless valid_sha256?(payload['sha256'])
        end
        snapshot = transaction['catalog_snapshot']
        raise ArgumentError, 'Invalid catalog snapshot.' unless snapshot.is_a?(Hash) && [true, false].include?(snapshot['existed'])
        raise ArgumentError, 'Invalid catalog snapshot hash.' if snapshot['existed'] && !valid_sha256?(snapshot['sha256'])
      end

      def transaction_root_path(transaction)
        FS.transaction_path(@lib_root, transaction.fetch('id'))
      end

      def prepare_delete_journal!(txid, item_id)
        payloads = TRANSACTION_PAYLOADS.map do |name|
          { 'name' => name, 'existed' => File.file?(v4_payload_path(item_id, name)) }
        end
        journal = {
          'version' => DELETE_JOURNAL_VERSION, 'id' => txid, 'state' => 'prepared', 'operation' => 'delete',
          'item_id' => item_id, 'phase' => 'prepared', 'payloads' => payloads
        }
        FileUtils.mkdir_p(FS.trash_path(@lib_root, txid))
        persist_delete_journal!(journal)
        journal
      end

      def delete_journal_path(txid)
        FS.trash_path(@lib_root, txid, 'delete.json')
      end

      def persist_delete_journal!(journal)
        atomic_write_json(delete_journal_path(journal.fetch('id')), journal)
      end

      def validate_delete_journal!(journal, path)
        raise ArgumentError, 'Invalid delete journal version.' unless journal['version'] == DELETE_JOURNAL_VERSION
        raise ArgumentError, 'Invalid delete transaction id.' unless journal['id'].to_s.match?(UUID_PATTERN)
        raise ArgumentError, 'Invalid delete item id.' unless journal['item_id'].to_s.match?(UUID_PATTERN)
        raise ArgumentError, 'Invalid delete operation.' unless journal['operation'] == 'delete'
        raise ArgumentError, 'Invalid delete state.' unless %w[prepared catalog_committed].include?(journal['state'])
        raise ArgumentError, 'Invalid delete phase.' unless %w[prepared model_moved preview_moved asset_moved complete].include?(journal['phase'])
        raise ArgumentError, 'Delete journal contains a path field.' if journal_contains_path_field?(journal)
        raise ArgumentError, 'Delete journal path does not match id.' unless File.expand_path(path) == delete_journal_path(journal['id'])
        payloads = journal['payloads']
        valid_payloads = payloads.is_a?(Array) && payloads.map { |payload| payload['name'] }.sort == TRANSACTION_PAYLOADS.sort &&
                         payloads.all? { |payload| payload.is_a?(Hash) && [true, false].include?(payload['existed']) }
        raise ArgumentError, 'Invalid delete payload list.' unless valid_payloads
      end

      def transaction_journal_path(txid)
        FS.transaction_path(@lib_root, txid, 'transaction.json')
      end

      def transaction_snapshot_path(transaction)
        FS.transaction_path(@lib_root, transaction.fetch('id'), 'library.json.before')
      end

      def transaction_payload_path(item_id, name)
        raise ArgumentError, 'Invalid transaction payload name.' unless TRANSACTION_PAYLOADS.include?(name)

        v4_payload_path(item_id, name)
      end

      def transaction_backup_path(transaction, name)
        FS.transaction_path(@lib_root, transaction.fetch('id'), 'before', name)
      end

      def transaction_staged_path(transaction, name)
        "#{transaction_payload_path(transaction['item_id'], name)}.new-#{transaction['id']}"
      end

      def v4_payload_path(item_id, name)
        rel = case name
              when 'model.skp' then FS.asset_model_rel_path(item_id)
              when 'preview.png' then FS.asset_preview_rel_path(item_id)
              when 'asset.json' then FS.asset_metadata_rel_path(item_id)
              else raise ArgumentError, 'Invalid v4 payload name.'
              end
        FS.to_full_path(@lib_root, rel)
      end

      def journal_contains_path_field?(value)
        case value
        when Hash
          value.any? { |key, child| key.to_s.match?(/path\z/i) || journal_contains_path_field?(child) }
        when Array
          value.any? { |child| journal_contains_path_field?(child) }
        else
          false
        end
      end

      def valid_sha256?(value)
        value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/i)
      end

      def sha256_file(path)
        Digest::SHA256.file(path).hexdigest
      end

      def atomic_write_bytes(path, bytes)
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory)
        tmp = "#{path}.#{SecureRandom.hex(8)}.tmp"
        File.binwrite(tmp, bytes)
        File.open(tmp, 'rb+') { |file| file.fsync }
        File.rename(tmp, path)
      ensure
        File.delete(tmp) if defined?(tmp) && tmp && File.file?(tmp)
      end

      def test_failure_after!(point)
        return unless ENV['CLB_TEST_MODE'] == '1' && ENV['CLB_TEST_FAILURE_AFTER'] == point

        raise "Test transaction failure after #{point}"
      end

      def load_or_initialize_index
        return load_v4_index if @format == :v4
        return default_index if @format == :legacy_read_only

        path = FS.index_path(@lib_root)
        return initialize_new_index(path) unless File.file?(path)

        begin
          parsed = JSON.parse(File.read(path))
          normalize_index(parsed)
        rescue StandardError
          initialize_new_index(path)
        end
      end

      def detect_format
        return :legacy_read_only if File.file?(FS.index_path(@lib_root))

        return :v4 if declared_v4_catalog?
        return :v4 if File.directory?(FS.assets_root(@lib_root))

        :v4
      end

      def v4_asset_tree?
        root = FS.assets_root(@lib_root)
        return false unless File.directory?(root)

        Dir.glob(File.join(root, '*.json')).any? do |manifest_path|
          id = File.basename(manifest_path, '.json')
          manifest = read_asset_manifest(id)
          asset, = normalize_v4_asset(id, manifest)
          !asset.nil?
        rescue StandardError
          false
        end
      end

      def declared_v4_catalog?
        path = FS.catalog_path(@lib_root)
        return false unless File.file?(path)

        catalog = JSON.parse(File.read(path, encoding: 'UTF-8'))
        catalog.is_a?(Hash) && catalog['version'] == FORMAT_V4
      rescue StandardError
        false
      end

      def complete_v4_catalog_activation?
        catalog = read_v4_catalog
        assets, = load_v4_assets
        catalog_matches_assets?(catalog, assets)
      end

      def load_v4_index
        assets, recovery = load_v4_assets
        catalog = read_v4_catalog
        unresolved_recovery = Array(@recovery_status && @recovery_status['transactions']).select { |entry| entry['status'] == 'recoverable' }
        unless catalog_matches_assets?(catalog, assets) || unresolved_recovery.any?
          catalog = rebuild_catalog_from_assets!(assets, catalog)
        end

        {
          'version' => FORMAT_V4,
          'created_at' => catalog_created_at(catalog),
          'updated_at' => FS.now_iso8601,
          'categories' => (assets.map { |asset| asset['category'] } + v4_extra_categories(catalog)).uniq.sort,
          'items' => assets,
          'recovery' => recovery + unresolved_recovery
        }
      end

      def load_v4_assets
        assets = []
        recovery = []
        root = FS.assets_root(@lib_root)
        return [assets, recovery] unless File.directory?(root)

        Dir.glob(File.join(root, '*.json')).sort.each do |manifest_path|
          directory_id = File.basename(manifest_path, '.json')
          begin
            manifest = read_asset_manifest(directory_id)
            asset, reason = normalize_v4_asset(directory_id, manifest)
            if asset
              assets << asset
            else
              recovery << v4_recovery_entry(directory_id, reason)
            end
          rescue StandardError => error
            recovery << v4_recovery_entry(directory_id, "unreadable manifest: #{error.class}")
          end
        end

        [assets.sort_by { |asset| asset['id'] }, recovery.sort_by { |entry| entry['id'] }]
      end

      def read_asset_manifest(asset_id)
        parsed = JSON.parse(File.read(v4_payload_path(asset_id, 'asset.json'), encoding: 'UTF-8'))
        raise ArgumentError, 'asset.json must contain an object.' unless parsed.is_a?(Hash)

        parsed
      end

      def normalize_v4_asset(asset_id, manifest)
        return [nil, 'asset id is not a UUID'] unless asset_id.match?(UUID_PATTERN)
        return [nil, 'manifest id does not match asset filename'] unless manifest['id'].to_s == asset_id
        return [nil, 'asset_version must be integer 1'] unless manifest['asset_version'].is_a?(Integer) && manifest['asset_version'] == 1
        return [nil, 'model is missing'] unless File.file?(v4_payload_path(asset_id, 'model.skp'))

        created_at = manifest['created_at']
        updated_at = manifest['updated_at']
        unless valid_timestamp?(created_at) && valid_timestamp?(updated_at)
          return [nil, 'manifest timestamp must be canonical UTC ISO-8601']
        end
        if Time.iso8601(updated_at) < Time.iso8601(created_at)
          return [nil, 'manifest timestamp updated_at precedes created_at']
        end

        [{
          'id' => asset_id,
          'name' => FS.normalize_display_name(manifest['name']),
          'category' => FS.normalize_category_name(manifest['category']),
          'description' => normalize_description(manifest['description']),
          'tags' => FS.normalize_tags(manifest['tags']),
          'favorite' => !!manifest['favorite'],
          'created_at' => created_at,
          'updated_at' => updated_at,
          'last_used_at' => manifest['last_used_at'],
          'skp_rel_path' => FS.asset_model_rel_path(asset_id),
          'thumb_rel_path' => FS.asset_preview_rel_path(asset_id),
          'source' => manifest['source'].to_s.empty? ? 'component' : manifest['source'].to_s,
          'file_size_bytes' => normalize_integer(manifest['file_size_bytes']),
          'bbox_xyz' => normalize_bbox(manifest['bbox_xyz']),
          'faces_count' => normalize_integer(manifest['faces_count']),
          'edges_count' => normalize_integer(manifest['edges_count']),
          'materials_count' => normalize_integer(manifest['materials_count']),
          'content_hash' => normalize_hash(manifest['content_hash']),
          'placement' => Services::Placement.normalize(manifest['placement'])
        }, nil]
      rescue ArgumentError => error
        [nil, error.message]
      end

      def read_v4_catalog
        path = FS.catalog_path(@lib_root)
        return nil unless File.file?(path)

        parsed = JSON.parse(File.read(path, encoding: 'UTF-8'))
        parsed.is_a?(Hash) ? parsed : nil
      rescue StandardError
        nil
      end

      def catalog_matches_assets?(catalog, assets)
        return false unless catalog.is_a?(Hash)
        return false unless (catalog.keys.sort == %w[assets created_at updated_at version] || catalog.keys.sort == %w[assets categories created_at updated_at version])
        return false unless catalog['version'] == FORMAT_V4
        return false unless valid_timestamp?(catalog['created_at']) && valid_timestamp?(catalog['updated_at'])
        return false unless Time.iso8601(catalog['created_at']) <= Time.iso8601(catalog['updated_at'])

        return false unless catalog['assets'] == v4_catalog_assets(assets)
        return true unless catalog.key?('categories')

        catalog['categories'].is_a?(Array) && catalog['categories'] == v4_extra_categories(catalog)
      end

      def rebuild_catalog_from_assets!(assets, existing_catalog = nil)
        now = FS.now_iso8601
        created_at = catalog_created_at(existing_catalog)
        created_at = now if Time.iso8601(created_at) > Time.iso8601(now)
        catalog = v4_catalog_for_assets(assets, existing_catalog, extra_categories: v4_extra_categories(existing_catalog))
        atomic_write_json(FS.catalog_path(@lib_root), catalog)
        catalog
      end

      def v4_catalog_assets(assets)
        assets.map do |asset|
          {
            'id' => asset['id'],
            'asset_rel_path' => FS.asset_metadata_rel_path(asset['id']),
            'updated_at' => asset['updated_at']
          }
        end.sort_by { |asset| asset['id'] }
      end

      def catalog_created_at(catalog)
        return catalog['created_at'] if catalog.is_a?(Hash) && valid_timestamp?(catalog['created_at'])

        FS.now_iso8601
      end

      def v4_recovery_entry(id, reason)
        { 'id' => id.to_s, 'status' => 'invalid', 'reason' => reason.to_s }
      end

      def initialize_new_index(path)
        created = default_index
        atomic_write_json(path, created)
        created
      end

      def default_index
        now = FS.now_iso8601
        {
          'version' => INDEX_VERSION,
          'created_at' => now,
          'updated_at' => now,
          'categories' => [],
          'items' => []
        }
      end

      def normalize_index(raw)
        now = FS.now_iso8601
        normalized = {
          'version' => [INDEX_VERSION, (raw['version'] || 1).to_i].max,
          'created_at' => raw['created_at'] || now,
          'updated_at' => raw['updated_at'] || now,
          'categories' => Array(raw['categories']).map { |c| FS.normalize_category_name(c) }.uniq.sort,
          'items' => []
        }

        Array(raw['items']).each do |item|
          next unless item.is_a?(Hash)
          next if item['id'].to_s.strip.empty?
          next if item['skp_rel_path'].to_s.strip.empty?

          normalized['items'] << {
            'id' => item['id'].to_s,
            'name' => FS.normalize_display_name(item['name']),
            'category' => FS.normalize_category_name(item['category']),
            'description' => normalize_description(item['description']),
            'tags' => FS.normalize_tags(item['tags']),
            'favorite' => !!item['favorite'],
            'created_at' => item['created_at'] || now,
            'updated_at' => item['updated_at'] || now,
            'last_used_at' => item['last_used_at'],
            'skp_rel_path' => item['skp_rel_path'].to_s.tr('\\', '/'),
            'thumb_rel_path' => item['thumb_rel_path'].to_s.tr('\\', '/'),
            'source' => item['source'].to_s.empty? ? 'component' : item['source'].to_s,
            'file_size_bytes' => normalize_integer(item['file_size_bytes']),
            'bbox_xyz' => normalize_bbox(item['bbox_xyz']),
            'faces_count' => normalize_integer(item['faces_count']),
            'edges_count' => normalize_integer(item['edges_count']),
            'materials_count' => normalize_integer(item['materials_count']),
            'content_hash' => normalize_hash(item['content_hash']),
            'placement' => Services::Placement.normalize(item['placement'])
          }
        end

        normalized['items'].each do |item|
          normalized['categories'] << item['category'] unless normalized['categories'].any? { |name| FS.same_name?(name, item['category']) }
        end

        normalized['categories'].uniq!
        normalized['categories'].sort!
        normalized
      end

      def persist_index!
        now = FS.now_iso8601
        @index['updated_at'] = now
        @index['version'] = [INDEX_VERSION, (@index['version'] || 1).to_i].max
        @index['categories'] ||= []
        @index['items'] ||= []

        @index['items'].each do |item|
          next if @index['categories'].any? { |name| FS.same_name?(name, item['category']) }
          @index['categories'] << item['category']
        end

        @index['categories'].uniq!
        @index['categories'].sort!
        atomic_write_json(FS.index_path(@lib_root), @index)
      end

      def atomic_write_json(path, data)
        directory = File.dirname(path)
        basename = File.basename(path)
        tmp_file = Tempfile.new(["#{basename}.", '.tmp'], directory, encoding: 'UTF-8')
        tmp_path = tmp_file.path

        tmp_file.write(JSON.pretty_generate(data))
        tmp_file.flush
        tmp_file.fsync
        tmp_file.close
        File.rename(tmp_path, path)
        tmp_path = nil
      ensure
        tmp_file.close if defined?(tmp_file) && tmp_file && !tmp_file.closed?
        File.delete(tmp_path) if defined?(tmp_path) && tmp_path && File.file?(tmp_path)
      end

      def require_item!(item_id)
        ensure_legacy_mutation!
        item = item_by_id(item_id)
        raise ArgumentError, 'Item not found.' unless item

        item
      end

      def category_exists?(name)
        @index['categories'].any? { |category| FS.same_name?(category, name) }
      end

      def ensure_category!(name)
        ensure_legacy_mutation!
        category = FS.normalize_category_name(name)
        add_category!(category) unless category_exists?(category)
        category
      end

      def category_path(name)
        existing = @index['categories'].find { |category| FS.same_name?(category, name) } || name
        FS.category_dir(@lib_root, existing)
      end

      def build_target_paths(category, name, short_id, item_id:)
        stem = FS.sanitize_segment(name, 'Item')
        filename = "#{stem}__#{short_id}"

        skp_rel_path = File.join('categories', category, "#{filename}.skp").tr('\\', '/')
        png_rel_path = File.join(FS::PREVIEWS_DIR, "#{item_id}.png").tr('\\', '/')
        skp_full_path = FS.to_full_path(@lib_root, skp_rel_path)
        png_full_path = FS.to_full_path(@lib_root, png_rel_path)

        {
          skp_rel_path: skp_rel_path,
          png_rel_path: png_rel_path,
          skp_full_path: skp_full_path,
          png_full_path: png_full_path
        }
      end

      def move_file(old_path, new_path)
        return unless File.file?(old_path)

        FileUtils.mkdir_p(File.dirname(new_path))
        FileUtils.mv(old_path, new_path)
      end

      def same_path?(left, right)
        File.expand_path(left).casecmp?(File.expand_path(right))
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def normalize_item_metadata_hash(metadata)
        metadata = {} unless metadata.is_a?(Hash)
        {
          'file_size_bytes' => normalize_integer(metadata['file_size_bytes']),
          'bbox_xyz' => normalize_bbox(metadata['bbox_xyz']),
          'faces_count' => normalize_integer(metadata['faces_count']),
          'edges_count' => normalize_integer(metadata['edges_count']),
          'materials_count' => normalize_integer(metadata['materials_count'])
        }
      end

      def normalize_integer(value)
        return nil if value.nil?

        int_value = value.to_i
        int_value.negative? ? nil : int_value
      rescue StandardError
        nil
      end

      def normalize_bbox(value)
        return nil unless value.is_a?(Array) && value.length == 3

        cleaned = value.map do |entry|
          next nil if entry.nil?
          float_value = entry.to_f
          float_value.finite? ? float_value : nil
        rescue StandardError
          nil
        end
        cleaned.all? ? cleaned : nil
      end

      def normalize_hash(value)
        hash = value.to_s.strip.downcase
        return nil if hash.empty?

        hash
      end

      def ensure_legacy_mutation!
        raise ArgumentError, 'Legacy libraries are read-only; create a new library folder.' if @format == :legacy_read_only
      end

      def valid_timestamp?(value)
        return false unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)

        Time.iso8601(value).utc.iso8601 == value
      rescue StandardError
        false
      end

      def normalize_description(value)
        value.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').strip
      rescue StandardError
        ''
      end
    end
  end
end
