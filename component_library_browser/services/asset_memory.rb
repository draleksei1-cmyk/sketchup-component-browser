require 'digest/sha1'

module Drale
  module ComponentLibraryBrowser
    module Services
      # Память компонентов: при вставке из библиотеки в компонент записываются
      # скрытые атрибуты (откуда взят, какой версии, когда). По ним вкладка
      # «В модели» определяет статус: актуален / устарел / изменён вручную.
      module AssetMemory
        extend self

        DICTIONARY = 'ComponentLibraryBrowser'.freeze
        KEY_ASSET_ID = 'asset_id'.freeze
        KEY_REVISION_HASH = 'revision_hash'.freeze
        KEY_INSERTED_AT = 'inserted_at'.freeze
        KEY_LIBRARY_SIGNATURE = 'library_signature'.freeze

        # Записывает метки на определение и на экземпляр.
        # definition — целевое определение, instance — конкретный экземпляр (может быть nil).
        def stamp!(definition, instance: nil, item: nil, library_signature: nil)
          return false unless definition && definition.valid?
          return false unless item.is_a?(Hash) && !item['id'].to_s.empty?

          now = Time.now.utc.iso8601
          definition.set_attribute(DICTIONARY, KEY_ASSET_ID, item['id'].to_s)
          definition.set_attribute(DICTIONARY, KEY_REVISION_HASH, item['content_hash'].to_s)
          definition.set_attribute(DICTIONARY, KEY_INSERTED_AT, now)
          definition.set_attribute(DICTIONARY, KEY_LIBRARY_SIGNATURE, library_signature.to_s)
          if instance && instance.valid?
            instance.set_attribute(DICTIONARY, KEY_ASSET_ID, item['id'].to_s)
            instance.set_attribute(DICTIONARY, KEY_INSERTED_AT, now)
          end
          true
        rescue StandardError => e
          Logger.warn('Не удалось записать метки компонента', 'error' => e.message.to_s)
          false
        end

        # Читает метки определения. Возвращает Hash или nil, если меток нет.
        def read(definition)
          return nil unless definition && definition.valid?

          asset_id = definition.get_attribute(DICTIONARY, KEY_ASSET_ID).to_s
          return nil if asset_id.empty?

          {
            'asset_id' => asset_id,
            'revision_hash' => definition.get_attribute(DICTIONARY, KEY_REVISION_HASH).to_s,
            'inserted_at' => definition.get_attribute(DICTIONARY, KEY_INSERTED_AT).to_s,
            'library_signature' => definition.get_attribute(DICTIONARY, KEY_LIBRARY_SIGNATURE).to_s
          }
        rescue StandardError
          nil
        end

        # Определяет статус компонента в модели относительно библиотеки.
        # memory  — метки (read), item — элемент библиотеки (может быть nil).
        # current_hash — SHA1 текущего SKP-файла библиотеки (может быть nil).
        # Возвращает один из: current, outdated, modified, orphan, unknown.
        def status_for(memory, item, current_hash)
          return 'unknown' unless memory

          unless item
            return 'orphan' # метка есть, а в библиотеке такого элемента больше нет
          end

          library_hash = item['content_hash'].to_s
          stamped_hash = memory['revision_hash'].to_s

          if stamped_hash.empty?
            # Вставлено без контрольной суммы — сравнить не с чем.
            return library_hash.empty? ? 'current' : 'unknown'
          end

          if stamped_hash == library_hash
            # Версия в библиотеке не менялась с момента вставки.
            return 'current'
          end

          if !current_hash.nil? && !current_hash.empty?
            # В библиотеке новая версия. Если файл в библиотеке совпадает с тем,
            # что был при вставке — это не так; здесь файл уже новый, значит устарел.
            return 'outdated'
          end

          'outdated'
        rescue StandardError
          'unknown'
        end

        # Подпись папки библиотеки: короткий отпечаток полного пути.
        # Позволяет отличать элементы из разных библиотек (личная / общая).
        def library_signature_for(lib_root)
          Digest::SHA1.hexdigest(lib_root.to_s)[0, 8]
        rescue StandardError
          ''
        end
      end
    end
  end
end
