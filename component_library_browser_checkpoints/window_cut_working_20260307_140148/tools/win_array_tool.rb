module Drale
  module ComponentLibraryBrowser
    module Tools
      class WinArrayTool
        ESC_KEY = 27
        ENTER_KEY = 13
        EPS = 1.0e-6
        PREVIEW_LIMIT = 200
        PREVIEW_SURFACE_OFFSET = 1.mm

        def initialize(controller)
          @controller = controller
          @input_point = Sketchup::InputPoint.new

          @source_definition = nil
          @preview_cache = empty_preview_cache
          @source_bbox_x = 0.0
          @source_bbox_y = 0.0
          @source_bbox_z = 0.0
          @source_scale_x = 1.0
          @source_scale_y = 1.0
          @source_scale_z = 1.0
          @source_anchor_offset = Geom::Vector3d.new(0, 0, 0)

          @params = {}

          @hover_point = ORIGIN
          @hover_normal = Z_AXIS
          @hover_has_face = false
          @hover_face = nil
          @hover_face_transform = nil
          @last_face = nil
          @last_face_transform = nil
          @hover_target = nil
          @last_valid_hover_target = nil
          @hover_valid = false

          @locked_origin = nil
          @locked_normal = nil
          @locked_has_face = false
          @locked_face = nil
          @locked_face_transform = nil
          @apply_target_snapshot = nil

          @last_mouse_x = nil
          @last_mouse_y = nil
        end

        def activate
          @controller.update_status_prompt
        end

        def deactivate(_view)
          Sketchup.status_text = ''
        end

        def onCancel(_reason, _view)
          @controller.cancel
        end

        def onRButtonDown(_flags, _x, _y, _view)
          @controller.cancel
        end

        def onKeyDown(key, _repeat, _flags, _view)
          case key
          when ESC_KEY
            @controller.cancel
          when ENTER_KEY
            @controller.apply
          end
        end

        def onMouseMove(_flags, x, y, view)
          @last_mouse_x = x
          @last_mouse_y = y
          update_hover(view, x, y)
          view.invalidate
        rescue StandardError
          nil
        end

        def onLButtonDown(_flags, x, y, view)
          @last_mouse_x = x
          @last_mouse_y = y
          update_hover(view, x, y)
          lock_current_hover
          capture_current_target!
          @controller.update_status_prompt
          view.invalidate
        rescue StandardError
          nil
        end

        def draw(view)
          if @input_point.valid? && @input_point.display?
            @input_point.draw(view)
            view.tooltip = @input_point.tooltip
          end

          return unless @source_definition&.valid?

          frame = current_frame
          return unless frame

          transforms = preview_transforms(frame)
          return if transforms.empty?

          draw_preview(view, transforms)
        rescue StandardError
          begin
            view.line_width = 1
          rescue StandardError
            nil
          end
        end

        def getExtents
          bounds = Geom::BoundingBox.new
          model = Sketchup.active_model
          bounds.add(model.bounds) if model

          frame = current_frame
          return bounds unless frame

          corners = definition_bounds_corners(@source_definition.bounds)
          return bounds if corners.empty?

          preview_transforms(frame).each do |tr|
            corners.each { |pt| bounds.add(pt.transform(tr)) }
          end
          bounds
        rescue StandardError
          Geom::BoundingBox.new
        end

        def set_source(definition, cache:, bbox_x:, bbox_y:, bbox_z: 0.0, scale_x: 1.0, scale_y: 1.0, scale_z: 1.0, **_ignored)
          @source_definition = definition
          @preview_cache = cache || empty_preview_cache
          @source_bbox_x = bbox_x.to_f
          @source_bbox_y = bbox_y.to_f
          @source_bbox_z = bbox_z.to_f
          @source_scale_x = sanitize_scale_factor(scale_x)
          @source_scale_y = sanitize_scale_factor(scale_y)
          @source_scale_z = sanitize_scale_factor(scale_z)
          @source_anchor_offset = source_anchor_offset_for(definition)
          reset_point!
        end

        def update_params(params)
          @params = params.is_a?(Hash) ? params : {}
        end

        def reset_point!
          @hover_target = nil
          @last_valid_hover_target = nil
          @hover_valid = false
          @apply_target_snapshot = nil

          @locked_origin = nil
          @locked_normal = nil
          @locked_has_face = false
          @locked_face = nil
          @locked_face_transform = nil

          @controller.update_status_prompt
        end

        def current_apply_target
          target = windows_target_snapshot_for_apply
          return nil unless target && target[:valid]

          face = resolve_snapshot_face(target)
          return nil unless face&.valid?

          entities = face.parent
          tr = target[:transform]
          return nil unless entities.is_a?(Sketchup::Entities) && tr.is_a?(Geom::Transformation)

          {
            face: face,
            face_pid: target[:face_pid],
            entities: entities,
            transform: tr,
            point: safe_point(target[:point]),
            axes: {
              x: safe_vector(target.dig(:axes, :x)),
              y: safe_vector(target.dig(:axes, :y)),
              z: safe_vector(target.dig(:axes, :z))
            }
          }
        rescue StandardError
          nil
        end

        def world_transforms_for_target(target)
          frame = current_frame_from_target(target)
          return [] unless frame

          build_transforms(frame, include_scale: false)
        rescue StandardError
          []
        end

        def suggested_auto_step_mm
          {
            'step_x_mm' => @source_bbox_x.to_f.to_mm.round(2),
            'step_y_mm' => @source_bbox_y.to_f.to_mm.round(2)
          }
        rescue StandardError
          nil
        end

        private

        def update_hover(view, x, y)
          @input_point.pick(view, x, y)
          if @input_point.valid?
            point = safe_point(@input_point.position)
            face = input_face(@input_point)
            face_transform = face_transform_from_input(@input_point, face)
            normal = world_normal_from_input(@input_point)

            if face.nil? || normal.nil? || face_transform.nil?
              ray_face, ray_point, ray_normal, ray_transform = raycast_face_from_view(view, x, y)
              face ||= ray_face
              normal ||= ray_normal
              point ||= ray_point
              face_transform ||= ray_transform
            end

            @hover_point = point || safe_point(@input_point.position) || ORIGIN
            @hover_face = face
            @hover_face_transform = face ? face_transform : nil
            if face&.valid?
              @last_face = face
              @last_face_transform = @hover_face_transform if @hover_face_transform.is_a?(Geom::Transformation)
            end
            if normal
              @hover_normal = normal
              @hover_has_face = true
            else
              @hover_normal = Z_AXIS
              @hover_has_face = false
            end
          else
            ray_face, ray_point, ray_normal, ray_transform = raycast_face_from_view(view, x, y)
            if ray_face && ray_point && ray_normal
              @hover_point = ray_point
              @hover_normal = ray_normal
              @hover_has_face = true
              @hover_face = ray_face
              @hover_face_transform = ray_transform
              if ray_face.valid?
                @last_face = ray_face
                @last_face_transform = ray_transform if ray_transform.is_a?(Geom::Transformation)
              end
            else
              @hover_point = project_ray_to_ground(view.pickray(x, y))
              @hover_normal = Z_AXIS
              @hover_has_face = false
              @hover_face = nil
              @hover_face_transform = nil
            end
          end

          if @hover_has_face && @hover_face&.valid?
            resolved_transform = resolve_face_transform_for_hover(@hover_face, @hover_face_transform)
            @hover_face_transform = resolved_transform if resolved_transform.is_a?(Geom::Transformation)
            update_windows_hover_target(@hover_face, @hover_face_transform, @hover_point)
          else
            @hover_valid = false
            @hover_target = nil
          end
        rescue StandardError
          @hover_valid = false
          @hover_target = nil
        end

        def lock_current_hover
          @locked_origin = safe_point(@hover_point)
          @locked_normal = safe_vector(@hover_normal)
          @locked_has_face = !!@hover_has_face
          if @hover_has_face
            @locked_face = @hover_face
            @locked_face_transform = @hover_face_transform
          end
        rescue StandardError
          nil
        end

        def capture_current_target!
          target = windows_target_snapshot_for_apply || current_windows_preview_target
          @apply_target_snapshot = duplicate_target_snapshot(target)
        rescue StandardError
          @apply_target_snapshot = nil
        end

        def current_reference
          if @locked_origin
            [@locked_origin, @locked_normal || Z_AXIS, @locked_has_face]
          else
            [safe_point(@hover_point), safe_vector(@hover_normal) || Z_AXIS, @hover_has_face]
          end
        end

        def current_frame
          target = current_windows_preview_target
          return nil unless target

          current_frame_from_target(target)
        rescue StandardError
          nil
        end

        def current_frame_from_target(target)
          axes = target[:axes].is_a?(Hash) ? target[:axes] : {}
          origin = safe_point(target[:point])
          x_axis = safe_vector(axes[:x])
          y_axis = safe_vector(axes[:y])
          z_axis = safe_vector(axes[:z])
          return nil unless origin && x_axis && y_axis && z_axis

          {
            origin: origin,
            u_axis: x_axis,
            v_axis: y_axis,
            layout_v_axis: y_axis,
            normal: z_axis
          }
        rescue StandardError
          nil
        end

        def build_transforms(frame, include_scale: false)
          count_x = [@params['count_x'].to_i, 1].max
          count_y = [@params['count_y'].to_i, 1].max

          step_x, step_y = step_lengths
          seam_x = [@params['seam_x_mm'].to_f, 0.0].max.mm
          seam_y = [@params['seam_y_mm'].to_f, 0.0].max.mm
          pitch_x = step_x + seam_x
          pitch_y = step_y + seam_y

          origin = frame[:origin]
          u_axis = frame[:u_axis]
          v_axis = frame[:layout_v_axis] || frame[:v_axis]
          normal = frame[:normal]
          return [] unless origin && u_axis && v_axis && normal

          transforms = []
          count_y.times do |row|
            count_x.times do |col|
              point = origin.offset(u_axis, col * pitch_x).offset(v_axis, row * pitch_y)
              tr = Geom::Transformation.axes(point, u_axis, v_axis, normal)
              tr = tr * Geom::Transformation.translation(@source_anchor_offset)
              if include_scale
                tr = tr * Geom::Transformation.scaling(@source_scale_x, @source_scale_y, @source_scale_z)
              end
              transforms << tr
            end
          end
          transforms
        rescue StandardError
          []
        end

        def preview_transforms(frame)
          normal = safe_vector(frame[:normal]) || Z_AXIS
          offset = Geom::Transformation.translation(normal.clone.normalize * PREVIEW_SURFACE_OFFSET)
          build_transforms(frame, include_scale: true).map { |tr| offset * tr }
        rescue StandardError
          build_transforms(frame, include_scale: true)
        end

        def step_lengths
          if @params['auto_step']
            step_x = @source_bbox_x.to_f
            step_y = @source_bbox_y.to_f
          else
            step_x = [@params['step_x_mm'].to_f, 1.0].max.mm
            step_y = [@params['step_y_mm'].to_f, 1.0].max.mm
          end

          step_x = 1.mm if step_x <= EPS
          step_y = 1.mm if step_y <= EPS
          [step_x, step_y]
        rescue StandardError
          [1000.mm, 1000.mm]
        end

        def draw_preview(view, transforms)
          edges = Array(@preview_cache['edges'])
          triangles = Array(@preview_cache['triangles'])
          return if edges.empty? && triangles.empty?

          sampled = sample_transforms(transforms)
          return if sampled.empty?

          unless triangles.empty?
            view.drawing_color = Sketchup::Color.new(82, 168, 211, 84)
            sampled.each do |tr|
              points = triangles.map { |pt| pt.transform(tr) }
              view.draw(GL_TRIANGLES, points) unless points.empty?
            end
          end

          unless edges.empty?
            view.drawing_color = Sketchup::Color.new(34, 105, 161)
            sampled.each do |tr|
              points = edges.map { |pt| pt.transform(tr) }
              view.draw(GL_LINES, points) unless points.empty?
            end
          end

          primary = sampled.first
          return unless primary

          unless triangles.empty?
            view.drawing_color = Sketchup::Color.new(46, 125, 255, 100)
            points = triangles.map { |pt| pt.transform(primary) }
            view.draw(GL_TRIANGLES, points) unless points.empty?
          end

          unless edges.empty?
            begin
              view.line_width = 2
            rescue StandardError
              nil
            end
            view.drawing_color = Sketchup::Color.new(24, 84, 235)
            points = edges.map { |pt| pt.transform(primary) }
            view.draw(GL_LINES, points) unless points.empty?
            begin
              view.line_width = 1
            rescue StandardError
              nil
            end
          end
        rescue StandardError
          begin
            view.line_width = 1
          rescue StandardError
            nil
          end
        end

        def sample_transforms(transforms)
          step = [(transforms.length.to_f / PREVIEW_LIMIT).ceil, 1].max
          sampled = []
          transforms.each_with_index do |tr, index|
            next unless (index % step).zero?

            sampled << tr
          end
          sampled
        rescue StandardError
          transforms
        end

        def update_windows_hover_target(face, face_transform, point_world)
          snapshot = build_windows_target_snapshot(face, face_transform, point_world, source: 'hover_preview')
          unless snapshot
            @hover_valid = false
            @hover_target = nil
            return
          end

          @hover_target = duplicate_target_snapshot(snapshot)
          @last_valid_hover_target = duplicate_target_snapshot(snapshot)
          @hover_valid = true
        rescue StandardError
          @hover_valid = false
          @hover_target = nil
        end

        def build_windows_target_snapshot(face, face_transform, point_world, source:)
          return nil unless face&.valid?

          face_transform = resolve_face_transform_for_hover(face, face_transform)
          return nil unless face_transform.is_a?(Geom::Transformation)

          normal = safe_vector(face.normal.transform(face_transform))
          return nil unless normal

          x_axis, y_axis, z_axis = window_axes_from_normal(normal)
          x_axis = safe_vector(x_axis)
          y_axis = safe_vector(y_axis)
          z_axis = safe_vector(z_axis)
          return nil unless x_axis && y_axis && z_axis

          entities = face.parent
          return nil unless entities.is_a?(Sketchup::Entities)

          point = safe_point(point_world)
          point ||= begin
            center = face.bounds.center
            center ? safe_point(center.transform(face_transform)) : nil
          rescue StandardError
            nil
          end
          point ||= begin
            vertex = face.vertices.first
            vertex ? safe_point(vertex.position.transform(face_transform)) : nil
          rescue StandardError
            nil
          end
          return nil unless point

          point = project_point_to_face_plane(point, face, face_transform, z_axis) || point

          duplicate_target_snapshot(
            {
              valid: true,
              face: face,
              face_pid: persistent_id_for(face),
              source: source.to_s,
              point: point,
              entities: entities,
              transform: face_transform,
              axes: {
                x: x_axis,
                y: y_axis,
                z: z_axis
              }
            }
          )
        rescue StandardError
          nil
        end

        def current_windows_preview_target
          if @hover_valid && @hover_target.is_a?(Hash)
            return duplicate_target_snapshot(@hover_target)
          end

          if @last_valid_hover_target.is_a?(Hash)
            return duplicate_target_snapshot(@last_valid_hover_target)
          end

          runtime_target = windows_target_from_runtime_state
          return runtime_target if runtime_target

          selected_face_target_snapshot
        rescue StandardError
          nil
        end

        def windows_target_snapshot_for_apply
          target = @apply_target_snapshot
          target = current_windows_preview_target unless target.is_a?(Hash)
          target = windows_target_from_runtime_state unless target.is_a?(Hash)
          return nil unless target.is_a?(Hash)

          duplicate_target_snapshot(target)
        rescue StandardError
          nil
        end

        def windows_target_from_runtime_state
          face = nil
          face_transform = nil

          if @hover_face&.valid?
            face = @hover_face
            face_transform = @hover_face_transform
          elsif @last_face&.valid?
            face = @last_face
            face_transform = @last_face_transform
          elsif @locked_face&.valid?
            face = @locked_face
            face_transform = @locked_face_transform
          end
          return nil unless face&.valid?

          tr = resolve_face_transform_for_hover(face, face_transform)
          point = @locked_origin || safe_point(@hover_point)
          build_windows_target_snapshot(face, tr, point, source: 'runtime')
        rescue StandardError
          nil
        end

        def selected_face_target_snapshot
          model = Sketchup.active_model
          return nil unless model

          selection = model.selection
          return nil unless selection && selection.count == 1

          face = selection.first
          return nil unless face.is_a?(Sketchup::Face) && face.valid?

          entities = face.parent
          return nil unless entities.is_a?(Sketchup::Entities)

          tr =
            if entities == model.active_entities
              model.edit_transform
            else
              Geom::Transformation.new
            end

          point = begin
            face.bounds.center.transform(tr)
          rescue StandardError
            nil
          end

          build_windows_target_snapshot(face, tr, point, source: 'selected_face')
        rescue StandardError
          nil
        end

        def resolve_snapshot_face(target)
          face = target[:face]
          return face if face&.valid?

          entities = target[:entities]
          resolve_face_by_pid(entities, target[:face_pid])
        rescue StandardError
          nil
        end

        def resolve_face_by_pid(entities, pid)
          return nil unless entities.is_a?(Sketchup::Entities)
          return nil unless pid.to_i.positive?

          entities.grep(Sketchup::Face).find do |face|
            face.valid? && face.respond_to?(:persistent_id) && face.persistent_id.to_i == pid.to_i
          end
        rescue StandardError
          nil
        end

        def duplicate_target_snapshot(target)
          return nil unless target.is_a?(Hash)

          axes = target[:axes].is_a?(Hash) ? target[:axes] : {}
          {
            valid: !!target[:valid],
            face: target[:face],
            face_pid: target[:face_pid],
            source: target[:source].to_s,
            point: safe_point(target[:point]),
            entities: target[:entities],
            transform: target[:transform].is_a?(Geom::Transformation) ? target[:transform] : nil,
            axes: {
              x: safe_vector(axes[:x]),
              y: safe_vector(axes[:y]),
              z: safe_vector(axes[:z])
            }
          }
        rescue StandardError
          nil
        end

        def resolve_face_transform_for_hover(face, candidate_transform)
          return candidate_transform if candidate_transform.is_a?(Geom::Transformation)
          return nil unless face&.valid?

          model = Sketchup.active_model
          return Geom::Transformation.new unless model

          return model.edit_transform if face.parent == model.active_entities
          return @last_face_transform if @last_face && face.equal?(@last_face) && @last_face_transform.is_a?(Geom::Transformation)
          return @hover_face_transform if @hover_face && face.equal?(@hover_face) && @hover_face_transform.is_a?(Geom::Transformation)
          return @locked_face_transform if @locked_face && face.equal?(@locked_face) && @locked_face_transform.is_a?(Geom::Transformation)

          Geom::Transformation.new
        rescue StandardError
          Geom::Transformation.new
        end

        def window_axes_from_normal(normal)
          z_axis = safe_vector(normal) || Z_AXIS
          y_axis = axis_on_plane(Z_AXIS, z_axis)
          y_axis = axis_on_plane(X_AXIS, z_axis) unless y_axis
          y_axis = axis_on_plane(Y_AXIS, z_axis) unless y_axis
          y_axis ||= Y_AXIS
          y_axis = safe_vector(y_axis) || Y_AXIS
          x_axis = safe_vector(y_axis.cross(z_axis))
          x_axis = axis_on_plane(X_AXIS, z_axis) unless x_axis
          x_axis = axis_on_plane(Y_AXIS, z_axis) unless x_axis
          x_axis ||= X_AXIS
          x_axis = safe_vector(x_axis) || X_AXIS
          y_axis = safe_vector(z_axis.cross(x_axis)) || y_axis
          [x_axis, y_axis, z_axis]
        rescue StandardError
          [X_AXIS, Y_AXIS, Z_AXIS]
        end

        def world_normal_from_input(input_point)
          return nil unless input_point&.valid?
          return nil unless input_point.respond_to?(:face)

          face = input_point.face
          return nil unless face

          normal = face.normal
          if input_point.respond_to?(:transformation)
            tr = input_point.transformation
            normal = normal.transform(tr) if tr
          end
          safe_vector(normal)
        rescue StandardError
          nil
        end

        def raycast_face_from_view(view, x, y)
          model = Sketchup.active_model
          return [nil, nil, nil, nil] unless model

          hit = model.raytest(view.pickray(x, y), false)
          return [nil, nil, nil, nil] unless hit.is_a?(Array) && hit.length == 2

          point = safe_point(hit[0])
          path = hit[1]
          return [nil, point, nil, nil] unless path.is_a?(Array)

          tr = Geom::Transformation.new
          face = nil
          edge = nil
          path.each do |entry|
            if entry.is_a?(Sketchup::Face)
              face = entry
              break
            end
            edge = entry if entry.is_a?(Sketchup::Edge)
            tr = tr * entry.transformation if entry.respond_to?(:transformation)
          end

          face = edge.faces.find(&:valid?) if !face && edge&.valid?
          tr = model.edit_transform if face&.valid? && face.parent == model.active_entities

          normal = face ? safe_vector(face.normal.transform(tr)) : nil
          [face, point, normal, tr]
        rescue StandardError
          [nil, nil, nil, nil]
        end

        def face_transform_from_input(input_point, face)
          return nil unless face
          return nil unless input_point

          tr = input_point.respond_to?(:transformation) ? input_point.transformation : nil
          return tr if tr.is_a?(Geom::Transformation)

          model = Sketchup.active_model
          return nil unless model
          return model.edit_transform if face.parent == model.active_entities

          nil
        rescue StandardError
          nil
        end

        def input_face(input_point)
          return nil unless input_point&.valid?
          return nil unless input_point.respond_to?(:face)

          face = input_point.face
          return nil unless face.is_a?(Sketchup::Face) && face.valid?

          face
        rescue StandardError
          nil
        end

        def project_point_to_face_plane(point, face, face_transform, normal)
          return nil unless point
          return nil unless face&.valid?
          return nil unless face_transform.is_a?(Geom::Transformation)

          origin = begin
            vertex = face.vertices.first
            vertex ? vertex.position.transform(face_transform) : nil
          rescue StandardError
            nil
          end
          origin ||= safe_point(point)
          return nil unless origin && normal

          safe_point(point).project_to_plane([origin, normal])
        rescue StandardError
          safe_point(point)
        end

        def axis_on_plane(vector, normal)
          projected = vector - normal * vector.dot(normal)
          safe_vector(projected)
        rescue StandardError
          nil
        end

        def project_ray_to_ground(ray)
          return ORIGIN unless ray && ray.length == 2

          origin = ray[0]
          direction = ray[1]
          return origin if direction.z.abs < EPS

          origin.offset(direction, -origin.z / direction.z)
        rescue StandardError
          ORIGIN
        end

        def source_anchor_offset_for(definition)
          return Geom::Vector3d.new(0, 0, 0) unless definition&.valid?

          bounds = definition.bounds
          min = bounds.min
          return Geom::Vector3d.new(0, 0, 0) unless min

          behavior = definition.respond_to?(:behavior) ? definition.behavior : nil
          cuts_opening = behavior && behavior.respond_to?(:cuts_opening?) ? !!behavior.cuts_opening? : false
          gluable = behavior && behavior.respond_to?(:is2d?) ? !!behavior.is2d? : false
          return Geom::Vector3d.new(0, 0, 0) if cuts_opening

          gluable ? Geom::Vector3d.new(0, 0, -min.z) : Geom::Vector3d.new(0, 0, 0)
        rescue StandardError
          Geom::Vector3d.new(0, 0, 0)
        end

        def opening_source_component?
          return false unless @source_definition&.valid?
          return false unless @source_definition.respond_to?(:behavior)

          behavior = @source_definition.behavior
          return false unless behavior && behavior.respond_to?(:cuts_opening?)

          !!behavior.cuts_opening?
        rescue StandardError
          false
        end

        def definition_bounds_corners(bounds)
          return [] unless bounds

          min = bounds.min
          max = bounds.max
          [
            Geom::Point3d.new(min.x, min.y, min.z),
            Geom::Point3d.new(max.x, min.y, min.z),
            Geom::Point3d.new(max.x, max.y, min.z),
            Geom::Point3d.new(min.x, max.y, min.z),
            Geom::Point3d.new(min.x, min.y, max.z),
            Geom::Point3d.new(max.x, min.y, max.z),
            Geom::Point3d.new(max.x, max.y, max.z),
            Geom::Point3d.new(min.x, max.y, max.z)
          ]
        rescue StandardError
          []
        end

        def safe_point(point)
          return nil unless point

          Geom::Point3d.new(point.x, point.y, point.z)
        rescue StandardError
          nil
        end

        def safe_vector(vector)
          return nil unless vector

          v = Geom::Vector3d.new(vector.x, vector.y, vector.z)
          return nil unless v.length > EPS

          v.normalize
        rescue StandardError
          nil
        end

        def sanitize_scale_factor(value)
          number = value.to_f
          number = 1.0 if number <= EPS
          number
        rescue StandardError
          1.0
        end

        def persistent_id_for(entity)
          return nil unless entity&.valid? && entity.respond_to?(:persistent_id)

          pid = entity.persistent_id.to_i
          pid.positive? ? pid : nil
        rescue StandardError
          nil
        end

        def empty_preview_cache
          {
            'edges' => [],
            'triangles' => [],
            'edge_segments' => 0,
            'triangle_count' => 0,
            'truncated' => false
          }
        end
      end
    end
  end
end
