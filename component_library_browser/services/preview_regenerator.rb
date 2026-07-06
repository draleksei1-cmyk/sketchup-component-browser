module Drale
  module ComponentLibraryBrowser
    module Services
      module PreviewRegenerator
        extend self

        def regenerate_item(storage, item)
          skp_path = FS.to_full_path(storage.lib_root, item['skp_rel_path'])
          png_path = FS.to_full_path(storage.lib_root, item['thumb_rel_path'])
          return false unless File.file?(skp_path)

          yield(skp_path, png_path) if block_given?
          true
        rescue StandardError
          false
        end

        def regenerate_many(storage, items)
          done = 0
          total = items.length
          items.each do |item|
            success = regenerate_item(storage, item) { |skp_path, png_path| yield(skp_path, png_path, done, total) if block_given? }
            done += 1 if success
          end
          { 'done' => done, 'total' => total }
        end
      end
    end
  end
end
