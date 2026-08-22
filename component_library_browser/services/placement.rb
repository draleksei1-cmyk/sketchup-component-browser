module Drale
  module ComponentLibraryBrowser
    module Services
      # Работа с паспортом размещения: точки привязки и починка приклейки
      # прорезных компонентов. Совместимо с Ruby 2.7.
      module Placement
        extend self

        ANCHORS = %w[center_bottom corner_lb corner_rb opening_center geometric_center custom].freeze

        # Нормализует паспорт из любого мусора в строгий Hash.
        DEFAULT_PLACEMENT = {
          'type' => 'free',
          'anchor' => 'center_bottom',
          'offset_z' => 0.0,
          'cut_opening' => false
        }.freeze

        TYPES = %w[free ground surface wall ceiling opening].freeze

        def normalize(raw)
          raw = {} unless raw.is_a?(Hash)
          type = raw['type'].to_s.strip.downcase
          anchor = raw['anchor'].to_s.strip.downcase
          offset_z = raw['offset_z'].to_f
          offset_z = 0.0 unless offset_z.finite? && offset_z >= 0.0

          {
            'type' => TYPES.include?(type) ? type : 'free',
            'anchor' => ANCHORS.include?(anchor) ? anchor : 'center_bottom',
            'offset_z' => offset_z,
            'cut_opening' => !!raw['cut_opening']
          }
        rescue StandardError
          normalize(nil)
        end

        def default_placement
          deep_copy(DEFAULT_PLACEMENT)
        end

        # Точка привязки в ЛОКАЛЬНЫХ координатах определения по его габаритам.
        # Возвращает nil для неизвестной/пользовательской привязки — тогда
        # замена работает по-старому (копия трансформации).
        def anchor_local_point(definition, anchor)
          return nil unless definition.respond_to?(:bounds)
          return nil unless ANCHORS.include?(anchor.to_s)

          bounds = definition.bounds
          center = bounds.center
          case anchor.to_s
          when 'center_bottom'
            Geom::Point3d.new(center.x, center.y, bounds.min.z)
          when 'corner_lb'
            Geom::Point3d.new(bounds.min.x, bounds.min.y, bounds.min.z)
          when 'corner_rb'
            Geom::Point3d.new(bounds.max.x, bounds.min.y, bounds.min.z)
          when 'opening_center', 'geometric_center'
            Geom::Point3d.new(center.x, center.y, center.z)
          else
            nil
          end
        rescue StandardError
          nil
        end

        # Вычисляет новую трансформацию для экземпляра так, чтобы точка привязки
        # целевого определения оказалась в той же точке модели, где была точка
        # привязки старого экземпляра. Одна и та же СМЫСЛОВАЯ привязка применяется
        # к обеим моделям — поэтому разные оси старого и нового окна не важны.
        #
        # Если хоть одна точка не вычисляется — возвращает исходную трансформацию
        # (поведение как раньше, ничего не ломаем).
        def adjusted_transformation(old_entity, target_definition, placement)
          old_tr = old_entity.transformation
          placement = normalize(placement)
          anchor = placement['anchor']
          return old_tr if placement['type'] == 'free' || anchor == 'custom'

          old_definition =
            if old_entity.respond_to?(:definition)
              old_entity.definition
            end
          return old_tr unless old_definition

          src_pt = anchor_local_point(old_definition, anchor)
          dst_pt = anchor_local_point(target_definition, anchor)
          return old_tr unless src_pt && dst_pt

          # Мировая точка, где была привязка старого экземпляра.
          world_pt = src_pt.transform(old_tr)
          # Где окажется привязка нового при копии трансформации.
          current_pt = dst_pt.transform(old_tr)
          offset = world_pt - current_pt
          return old_tr if offset.length < 1.0e-9

          # Чистый мировой сдвиг поверх существующей трансформации.
          old_tr * Geom::Transformation.translation(offset)
        rescue StandardError
          old_tr
        end

        # Починка приклейки прорезного компонента: если у определения включено
        # прорезание, а экземпляр после вставки не приклеен — ищем грань-хозяина
        # среди граней родительского контейнера и приклеиваем.
        # Возвращает true, если приклейку удалось дотянуть.
        def ensure_cutting_glue!(instance, definition)
          return false unless instance && instance.valid?
          return false unless definition.respond_to?(:behavior)

          behavior = definition.behavior
          cuts = behavior && behavior.respond_to?(:cuts_opening?) ? behavior.cuts_opening? : false
          unless cuts
            Logger.debug('Приклейка не требуется: компонент не прорезной')
            return false
          end

          glued = instance.respond_to?(:glued_to) ? instance.glued_to : nil
          if glued && glued.valid?
            Logger.debug('Приклейка в норме', 'glued_to' => glued.to_s)
            return true
          end

          face = find_host_face(instance)
          return false unless face

          begin
            instance.glued_to = face
            Logger.info(
              'Вставка: дотянули приклейку прорезного компонента',
              {
                'definition' => definition.name.to_s,
                'face' => face.entityID.to_s
              }
            )
            true
          rescue StandardError => e
            Logger.warn('Не удалось дотянуть приклейку', 'error' => e.message.to_s)
            false
          end
        rescue StandardError => e
          Logger.warn('Ошибка проверки приклейки', 'error' => e.message.to_s)
          false
        end

        private

        # Ищет грань-хозяина среди прямых граней родителя экземпляра:
        # берём грань, чьи габариты содержат точку вставки экземпляра.
        def find_host_face(instance)
          parent = instance.parent
          return nil unless parent.respond_to?(:entities)

          origin = instance.transformation.origin
          candidates = []
          parent.entities.grep(Sketchup::Face).each do |face|
            next unless face.valid?

            bounds = face.bounds
            next unless bounds.contains?(origin)

            distance = face.plane[0] * origin.x + face.plane[1] * origin.y + face.plane[2] * origin.z + face.plane[3]
            candidates << [distance.abs, face]
          end
          return nil if candidates.empty?

          # Самая близкая по плоскости грань — вероятный хозяин.
          candidates.sort_by { |distance, _face| distance }.first[1]
        rescue StandardError
          nil
        end
      end
    end
  end
end
