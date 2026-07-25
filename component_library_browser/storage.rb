require 'json'
require 'fileutils'
require 'securerandom'
require 'time'

require_relative 'fs'
require_relative 'compat'

module Drale
  module ComponentLibraryBrowser
    class Storage
      FORMAT_V3 = 3
      FORMAT_V4 = 4
      INDEX_VERSION = FORMAT_V3
      UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze

      attr_reader :lib_root

      def initialize(lib_root)
        raise ArgumentError, 'Library path is empty.' if lib_root.to_s.strip.empty?

        @lib_root = File.expand_path(lib_root)
        @format = detect_format
        FS.ensure_library_structure(@lib_root) unless @format == :v4
        @index = load_or_initialize_index
      end

      def index
        deep_copy(@index)
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
        item = require_item!(item_id)
        item['favorite'] = !!value
        item['updated_at'] = FS.now_iso8601
        persist_index!
        item
      end

      def update_item_metadata!(item_id, attrs = {})
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
        item = require_item!(item_id)
        item['content_hash'] = normalize_hash(hash_value)
        item['updated_at'] = FS.now_iso8601
        persist_index!
        item
      end

      def replace_item_definition!(item_id, definition, source:, metadata: nil, content_hash: nil)
        raise ArgumentError, 'Definition is required.' unless definition

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
        item = require_item!(item_id)
        now = FS.now_iso8601
        item['last_used_at'] = now
        item['updated_at'] = now
        persist_index!
      end

      def delete_item!(item_id)
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
          'content_hash' => normalize_hash(content_hash)
        }

        @index['items'] << item
        persist_index!
        { 'item' => item, 'name_changed' => name_changed, 'requested_name' => requested_name, 'final_name' => final_name }
      end

      def edit_item!(item_id, attrs)
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
              'content_hash' => existing_item ? normalize_hash(existing_item['content_hash']) : nil
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

      def load_or_initialize_index
        return load_v4_index if @format == :v4

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
        return :v4 if File.directory?(FS.assets_root(@lib_root))
        return :v3 if File.file?(FS.index_path(@lib_root))

        :empty
      end

      def load_v4_index
        assets, recovery = load_v4_assets
        catalog = read_v4_catalog
        catalog = rebuild_catalog_from_assets!(assets, catalog) unless catalog_matches_assets?(catalog, assets)

        {
          'version' => FORMAT_V4,
          'created_at' => catalog_created_at(catalog),
          'updated_at' => FS.now_iso8601,
          'categories' => assets.map { |asset| asset['category'] }.uniq.sort,
          'items' => assets,
          'recovery' => recovery
        }
      end

      def load_v4_assets
        assets = []
        recovery = []
        root = FS.assets_root(@lib_root)
        return [assets, recovery] unless File.directory?(root)

        Dir.glob(File.join(root, '*')).sort.each do |asset_dir|
          next unless File.directory?(asset_dir)

          directory_id = File.basename(asset_dir)
          begin
            manifest = read_asset_manifest(asset_dir)
            asset, reason = normalize_v4_asset(directory_id, manifest, asset_dir)
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

      def read_asset_manifest(asset_dir)
        parsed = JSON.parse(File.read(File.join(asset_dir, 'asset.json'), encoding: 'UTF-8'))
        raise ArgumentError, 'asset.json must contain an object.' unless parsed.is_a?(Hash)

        parsed
      end

      def normalize_v4_asset(directory_id, manifest, asset_dir)
        return [nil, 'asset directory is not a UUID'] unless directory_id.match?(UUID_PATTERN)
        return [nil, 'manifest id does not match asset directory'] unless manifest['id'].to_s == directory_id
        return [nil, 'model.skp is missing'] unless File.file?(File.join(asset_dir, 'model.skp'))

        metadata_path = File.join(asset_dir, 'asset.json')
        fallback_time = File.mtime(metadata_path).utc.iso8601
        created_at = normalize_timestamp(manifest['created_at'], fallback_time)
        updated_at = normalize_timestamp(manifest['updated_at'], created_at)

        [{
          'id' => directory_id,
          'name' => FS.normalize_display_name(manifest['name']),
          'category' => FS.normalize_category_name(manifest['category']),
          'description' => normalize_description(manifest['description']),
          'tags' => FS.normalize_tags(manifest['tags']),
          'favorite' => !!manifest['favorite'],
          'created_at' => created_at,
          'updated_at' => updated_at,
          'last_used_at' => manifest['last_used_at'],
          'skp_rel_path' => FS.asset_model_rel_path(directory_id),
          'thumb_rel_path' => FS.asset_preview_rel_path(directory_id),
          'source' => manifest['source'].to_s.empty? ? 'component' : manifest['source'].to_s,
          'file_size_bytes' => normalize_integer(manifest['file_size_bytes']),
          'bbox_xyz' => normalize_bbox(manifest['bbox_xyz']),
          'faces_count' => normalize_integer(manifest['faces_count']),
          'edges_count' => normalize_integer(manifest['edges_count']),
          'materials_count' => normalize_integer(manifest['materials_count']),
          'content_hash' => normalize_hash(manifest['content_hash'])
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
        return false unless catalog.keys.sort == %w[assets created_at updated_at version]
        return false unless catalog['version'].to_i == FORMAT_V4
        return false unless valid_timestamp?(catalog['created_at']) && valid_timestamp?(catalog['updated_at'])

        catalog['assets'] == v4_catalog_assets(assets)
      end

      def rebuild_catalog_from_assets!(assets, existing_catalog = nil)
        now = FS.now_iso8601
        catalog = {
          'version' => FORMAT_V4,
          'created_at' => catalog_created_at(existing_catalog),
          'updated_at' => now,
          'assets' => v4_catalog_assets(assets)
        }
        atomic_write_json(FS.catalog_path(@lib_root), catalog)
        catalog
      end

      def v4_catalog_assets(assets)
        assets.map do |asset|
          {
            'id' => asset['id'],
            'asset_rel_path' => File.join(FS::ASSETS_DIR, asset['id']).tr('\\', '/'),
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
            'content_hash' => normalize_hash(item['content_hash'])
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
        tmp_path = "#{path}.tmp"
        json = JSON.pretty_generate(data)
        File.write(tmp_path, json, mode: 'w:UTF-8')
        FileUtils.mv(tmp_path, path, force: true)
      ensure
        File.delete(tmp_path) if defined?(tmp_path) && File.file?(tmp_path)
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
        raise ArgumentError, 'v4 libraries are read-only.' if @format == :v4
      end

      def normalize_timestamp(value, fallback)
        return fallback if value.to_s.strip.empty?

        Time.parse(value.to_s).utc.iso8601
      rescue StandardError
        fallback
      end

      def valid_timestamp?(value)
        !value.to_s.strip.empty? && Time.parse(value.to_s)
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
