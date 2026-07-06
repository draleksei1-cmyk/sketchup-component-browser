module Drale
  module ComponentLibraryBrowser
    module Tools
      class InsertBrushTool
        ESC_KEY = 27

        def initialize(definition, options = {}, continuous: true, on_place: nil, on_exit: nil)
          @definition = definition
          @options = normalize_options(options)
          @continuous = !!continuous
          @on_place = on_place
          @on_exit = on_exit
          @input_point = Sketchup::InputPoint.new
        end

        def activate
          update_status_text
        end

        def deactivate(_view)
          Sketchup.status_text = ''
          @on_exit.call if @on_exit
        end

        def onCancel(_reason, view)
          view.model.select_tool(nil)
        end

        def onRButtonDown(_flags, _x, _y, view)
          view.model.select_tool(nil)
        end

        def onKeyDown(key, _repeat, _flags, view)
          return unless key == ESC_KEY

          view.model.select_tool(nil)
        end

        def onMouseMove(_flags, x, y, view)
          @input_point.pick(view, x, y)
          view.invalidate
        rescue StandardError
          # ignore hover errors
        end

        def draw(view)
          return unless @input_point && @input_point.valid?

          @input_point.draw(view)
          view.tooltip = @input_point.tooltip
        rescue StandardError
          # ignore draw errors
        end

        def update_options(options)
          @options = normalize_options(options)
          update_status_text
        end

        def onLButtonDown(_flags, x, y, view)
          return unless @definition

          @input_point.pick(view, x, y)
          transformation = build_transformation(view, x, y)

          instance = view.model.active_entities.add_instance(@definition, transformation)
          apply_ground_snap(instance, view.model) if @options['drop_to_ground']
          @on_place.call(instance) if @on_place

          view.model.select_tool(nil) unless @continuous
        rescue StandardError
          # placement errors should not crash SketchUp tool loop
        ensure
          view.invalidate
        end

        private

        def update_status_text
          flags = []
          flags << 'поверхность' if @options['place_on_surface']
          flags << 'нормаль' if @options['align_to_normal']
          flags << 'рандом 90' if @options['random_quadrant']
          flags << 'к земле' if @options['drop_to_ground']
          suffix = flags.empty? ? '' : " (#{flags.join(', ')})"

          if @continuous
            Sketchup.status_text = "Многократная вставка: клик для установки, Esc/ПКМ для выхода#{suffix}."
          else
            Sketchup.status_text = "Вставка: выберите точку в модели, Esc/ПКМ для отмены#{suffix}."
          end
        end

        def normalize_options(options)
          data = options.is_a?(Hash) ? options : {}
          {
            'place_on_surface' => !!data['place_on_surface'],
            'align_to_normal' => !!data['align_to_normal'],
            'random_quadrant' => !!data['random_quadrant'],
            'drop_to_ground' => !!data['drop_to_ground']
          }
        end

        def picked_position(view, x, y)
          world_point =
            if @options['place_on_surface'] && @input_point.valid?
              @input_point.position
            else
              ray = view.pickray(x, y)
              project_ray_to_ground(ray)
            end

          world_point.transform(view.model.edit_transform.inverse)
        rescue StandardError
          ORIGIN
        end

        def project_ray_to_ground(ray)
          return ORIGIN unless ray && ray.length == 2

          origin = ray[0]
          direction = ray[1]
          return origin if direction.z.abs < 1.0e-6

          t = -origin.z / direction.z
          origin.offset(direction, t)
        rescue StandardError
          ORIGIN
        end

        def picked_face_normal_local(view)
          return nil unless @input_point.valid?

          face = @input_point.face
          return nil unless face

          normal_world = face.normal
          return nil unless normal_world && normal_world.length > 0.0

          normal_local = normal_world.transform(view.model.edit_transform.inverse)
          return nil unless normal_local && normal_local.length > 0.0

          normal_local
        rescue StandardError
          nil
        end

        def build_transformation(view, x, y)
          position = picked_position(view, x, y)
          zaxis = Geom::Vector3d.new(0, 0, 1)

          if @options['align_to_normal']
            normal = picked_face_normal_local(view)
            zaxis = normal if normal && normal.length > 0.0
          end
          zaxis.normalize!

          xaxis = Geom::Vector3d.new(1, 0, 0)
          xaxis = Geom::Vector3d.new(0, 1, 0) if xaxis.parallel?(zaxis)
          xaxis = xaxis.cross(zaxis)
          xaxis.normalize!
          yaxis = zaxis.cross(xaxis)
          yaxis.normalize!

          tr = Geom::Transformation.axes(position, xaxis, yaxis, zaxis)

          if @options['random_quadrant']
            angle = [0, 90, 180, 270].sample.degrees
            tr = tr * Geom::Transformation.rotation(position, zaxis, angle)
          end

          tr
        end

        def apply_ground_snap(instance, model)
          return unless instance && instance.valid?
          return unless model

          delta_world = -instance.bounds.min.z
          return if delta_world.abs < 0.001

          world_move = Geom::Transformation.translation([0, 0, delta_world])
          edit = model.edit_transform
          local_move = edit.inverse * world_move * edit
          instance.transform!(local_move)
        rescue StandardError
          # ignore snap errors
        end
      end
    end
  end
end
