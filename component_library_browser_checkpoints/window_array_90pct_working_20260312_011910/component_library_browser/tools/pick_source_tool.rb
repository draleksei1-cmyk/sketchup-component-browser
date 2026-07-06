module Drale
  module ComponentLibraryBrowser
    module Tools
      class PickSourceTool
        ESC_KEY = 27

        def initialize(on_pick: nil, on_cancel: nil)
          @on_pick = on_pick
          @on_cancel = on_cancel
          @input_point = Sketchup::InputPoint.new
        end

        def activate
          Sketchup.status_text = 'Пипетка: кликните по компоненту или группе. Esc/ПКМ - отмена.'
        end

        def deactivate(_view)
          Sketchup.status_text = ''
        end

        def onMouseMove(_flags, x, y, view)
          @input_point.pick(view, x, y)
          view.invalidate
        rescue StandardError
          # ignore hover failures
        end

        def draw(view)
          return unless @input_point.valid?

          @input_point.draw(view)
          view.tooltip = @input_point.tooltip
        rescue StandardError
          # ignore draw failures
        end

        def onLButtonDown(_flags, x, y, view)
          pick_data = pick_entity(view, x, y)
          unless pick_data
            UI.beep if UI.respond_to?(:beep)
            return
          end

          entity = pick_data[:entity]
          world_transform = pick_data[:world_transform]
          definition = entity.definition
          name = definition.name.to_s.strip
          name = entity.is_a?(Sketchup::Group) ? 'Группа' : 'Компонент' if name.empty?
          @on_pick.call(definition, name, entity, world_transform) if @on_pick
        rescue StandardError
          UI.beep if UI.respond_to?(:beep)
        ensure
          view.invalidate
        end

        def onRButtonDown(_flags, _x, _y, _view)
          cancel_pick
        end

        def onCancel(_reason, _view)
          cancel_pick
        end

        def onKeyDown(key, _repeat, _flags, _view)
          cancel_pick if key == ESC_KEY
        end

        private

        def pick_entity(view, x, y)
          pick_helper = view.pick_helper
          pick_helper.do_pick(x, y)

          path = pick_helper.path_at(0)
          if path.is_a?(Array) && !path.empty?
            picked = path.reverse.find { |entry| entry.is_a?(Sketchup::ComponentInstance) || entry.is_a?(Sketchup::Group) }
            return nil unless picked

            world_transform = cumulative_transform_for_path(path, picked)
            return { entity: picked, world_transform: world_transform }
          end

          best = pick_helper.best_picked
          return nil unless best.is_a?(Sketchup::ComponentInstance) || best.is_a?(Sketchup::Group)

          {
            entity: best,
            world_transform: best.respond_to?(:transformation) ? best.transformation : Geom::Transformation.new
          }
        rescue StandardError
          nil
        end

        def cumulative_transform_for_path(path, target)
          transform = Geom::Transformation.new
          path.each do |entry|
            if entry.is_a?(Sketchup::ComponentInstance) || entry.is_a?(Sketchup::Group)
              transform = transform * entry.transformation
            end
            break if entry.equal?(target)
          end
          transform
        rescue StandardError
          Geom::Transformation.new
        end

        def cancel_pick
          @on_cancel.call if @on_cancel
        rescue StandardError
          # ignore callback failures
        end
      end
    end
  end
end
