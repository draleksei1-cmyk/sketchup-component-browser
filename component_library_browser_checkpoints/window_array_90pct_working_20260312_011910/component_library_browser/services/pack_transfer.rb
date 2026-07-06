require 'json'
require 'fileutils'
require 'time'
require 'tmpdir'
require_relative '../compat'

module Drale
  module ComponentLibraryBrowser
    module Services
      module PackTransfer
        extend self

        def export_pack(storage:, mode:, category: nil, destination_root:, zip: false)
          raise ArgumentError, 'Хранилище не задано.' unless storage

          items = select_items(storage, mode, category)
          raise ArgumentError, 'Нет элементов для экспорта.' if items.empty?

          timestamp = Time.now.utc.strftime('%Y%m%d_%H%M%S')
          label = mode == 'favorites' ? 'favorites' : FS.sanitize_segment(category.to_s, 'category')
          pack_root = File.join(destination_root, 'exports', "#{timestamp}_#{label}")
          FileUtils.mkdir_p(pack_root)

          exported_items = []
          items.each do |item|
            skp_src = FS.to_full_path(storage.lib_root, item['skp_rel_path'])
            png_src = FS.to_full_path(storage.lib_root, item['thumb_rel_path'])
            next unless File.file?(skp_src)

            skp_dst = File.join(pack_root, item['skp_rel_path'])
            png_dst = File.join(pack_root, item['thumb_rel_path'])
            FileUtils.mkdir_p(File.dirname(skp_dst))
            FileUtils.mkdir_p(File.dirname(png_dst))
            FileUtils.cp(skp_src, skp_dst)
            FileUtils.cp(png_src, png_dst) if File.file?(png_src)
            exported_items << item
          end

          index = {
            'version' => 1,
            'created_at' => Time.now.utc.iso8601,
            'source_lib_root' => storage.lib_root,
            'mode' => mode,
            'category' => category,
            'items' => exported_items
          }
          File.write(File.join(pack_root, 'pack_index.json'), JSON.pretty_generate(index), mode: 'w:UTF-8')

          zip_path = nil
          if zip
            zip_path = "#{pack_root}.zip"
            system('powershell', '-NoProfile', '-Command', "Compress-Archive -Path '#{pack_root}\\*' -DestinationPath '#{zip_path}' -Force")
          end

          {
            'pack_root' => pack_root,
            'zip_path' => zip_path,
            'count' => exported_items.length
          }
        end

        def import_pack(storage:, pack_path:, model:, on_item: nil, dedupe: nil)
          raise ArgumentError, 'Хранилище не задано.' unless storage
          raise ArgumentError, 'Путь pack не задан.' if pack_path.to_s.strip.empty?

          root, cleanup = resolve_pack_root(pack_path)
          index_path = File.join(root, 'pack_index.json')
          raise ArgumentError, 'pack_index.json не найден.' unless File.file?(index_path)

          payload = JSON.parse(File.read(index_path))
          items = Array(payload['items'])
          imported = 0
          skipped = 0

          items.each do |item|
            next unless item.is_a?(Hash)

            if dedupe && dedupe.call(item)
              skipped += 1
              next
            end

            skp_src = File.join(root, item['skp_rel_path'].to_s.tr('/', File::SEPARATOR))
            png_src = File.join(root, item['thumb_rel_path'].to_s.tr('/', File::SEPARATOR))
            unless File.file?(skp_src)
              skipped += 1
              next
            end

            definition = Compat.load_definition_from_file(
              skp_src,
              definitions: model.definitions,
              context: 'import_pack',
              library_path: storage.lib_root
            )
            saved = storage.save_definition!(
              definition,
              source: item['source'].to_s.empty? ? 'component' : item['source'].to_s,
              category: item['category'].to_s.empty? ? 'Импорт' : item['category'],
              display_name: item['name'].to_s.empty? ? FS.display_name_from_skp(skp_src) : item['name'],
              tags: item['tags'] || [],
              content_hash: item['content_hash'],
              description: item['description']
            )

            saved_item = saved['item']
            if File.file?(png_src)
              png_target = FS.to_full_path(storage.lib_root, saved_item['thumb_rel_path'])
              FileUtils.mkdir_p(File.dirname(png_target))
              FileUtils.cp(png_src, png_target, force: true)
            end

            on_item.call(saved_item, skp_src) if on_item
            imported += 1
          rescue StandardError
            skipped += 1
          end

          {
            'imported' => imported,
            'skipped' => skipped
          }
        ensure
          cleanup.call if cleanup
        end

        private

        def select_items(storage, mode, category)
          items = storage.index['items']
          case mode
          when 'favorites'
            items.select { |item| item['favorite'] }
          when 'category'
            items.select { |item| FS.same_name?(item['category'], category.to_s) }
          else
            []
          end
        end

        def resolve_pack_root(path)
          expanded = File.expand_path(path)
          if File.directory?(expanded)
            return [expanded, nil]
          end

          unless File.file?(expanded) && File.extname(expanded).casecmp?('.zip')
            raise ArgumentError, 'Укажите папку pack или zip-файл.'
          end

          tmp_dir = Dir.mktmpdir('clb_pack_')
          system('powershell', '-NoProfile', '-Command', "Expand-Archive -Path '#{expanded}' -DestinationPath '#{tmp_dir}' -Force")
          [tmp_dir, proc { FileUtils.remove_entry(tmp_dir) if File.directory?(tmp_dir) }]
        end
      end
    end
  end
end
