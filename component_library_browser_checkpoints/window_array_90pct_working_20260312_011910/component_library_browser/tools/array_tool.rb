module Drale
  module ComponentLibraryBrowser
    module Tools
      class ArrayTool
        ESC_KEY = 27
        ENTER_KEY = 13
        R_KEY_UP = 82
        R_KEY_DOWN = 114
        EPS = 1.0e-6

        def initialize(controller)
          @controller = controller
          @input_point = Sketchup::InputPoint.new
          @hover_point = ORIGIN
          @hover_normal = Z_AXIS
          @hover_has_face = false
          @hover_valid = false
          @locked_origin = nil
          @locked_normal = nil
          @locked_has_face = false
          @hover_face = nil
          @locked_face = nil
          @hover_face_transform = nil
          @locked_face_transform = nil
          @last_face = nil
          @last_face_transform = nil
          @last_mouse_x = nil
          @last_mouse_y = nil
          @params = {}
          @source_definition = nil
          @source_bbox_x = 0.0
          @source_bbox_y = 0.0
          @source_bbox_z = 0.0
          @source_scale_x = 1.0
          @source_scale_y = 1.0
          @source_scale_z = 1.0
          @source_anchor_offset = Geom::Vector3d.new(0, 0, 0)
          @preview_cache = empty_preview_cache
          @hover_target = nil
          @last_valid_hover_target = nil
          @locked_window_target_snapshot = nil
          @apply_target_snapshot = nil
          @debug_last_hover_signature = nil
          @debug_last_hover_log_at = 0.0
          @last_logged_hover_face_pid = nil
          @native_window_axes_cache = {}
          @source_window_prototype_state = nil
        end

        def activate
          @controller.update_status_prompt
          debug_log('array_tool_activated', { 'version_marker' => 'camera_normal_fix_v2', 'mode' => @params['mode'].to_s })
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
          when R_KEY_UP, R_KEY_DOWN
            @controller.reset_point
          end
        end

        def onMouseMove(_flags, x, y, view)
          @last_mouse_x = x
          @last_mouse_y = y
          update_hover(view, x, y)
          debug_hover_state('mousemove', x: x, y: y)
          view.invalidate
        rescue StandardError
          # ignore hover errors
        end

        def onLButtonDown(_flags, x, y, view)
          @last_mouse_x = x
          @last_mouse_y = y
          update_hover(view, x, y)
          lock_current_hover
          debug_log('lbutton_down', debug_snapshot.merge('x' => x, 'y' => y))
          @controller.update_status_prompt
          view.invalidate
        rescue StandardError
          # ignore lock errors
        end

        def draw(view)
          return unless @source_definition && @source_definition.valid?

          # Always draw the InputPoint snapping indicator first so the cursor
          # helper dot appears regardless of whether a preview frame is available.
          if @input_point.valid?
            @input_point.draw(view)
            view.tooltip = @input_point.tooltip
          end

          frame = current_frame
          return unless frame

          transforms = build_transforms(frame, preview: true)
          return if transforms.empty?

          draw_preview(view, transforms)
          draw_primary_preview(view, transforms.first)
        rescue StandardError
          # keep tool stable on draw errors
        end

        # Helps SketchUp camera clipping include tool preview geometry.
        def getExtents
          bounds = Geom::BoundingBox.new
          model = Sketchup.active_model
          bounds.add(model.bounds) if model

          return bounds unless @source_definition && @source_definition.valid?

          frame = current_frame
          return bounds unless frame

          transforms = build_transforms(frame, preview: true)
          return bounds if transforms.empty?

          corners = definition_bounds_corners(@source_definition.bounds)
          return bounds if corners.empty?

          transforms.each do |tr|
            corners.each { |pt| bounds.add(pt.transform(tr)) }
          end
          bounds
        rescue StandardError
          model = Sketchup.active_model
          model ? model.bounds : Geom::BoundingBox.new
        end

        def set_source(definition, cache:, bbox_x:, bbox_y:, bbox_z: 0.0, scale_x: 1.0, scale_y: 1.0, scale_z: 1.0, source_window_state: nil)
          @source_definition = definition
          @preview_cache = cache || empty_preview_cache
          @source_bbox_x = bbox_x.to_f
          @source_bbox_y = bbox_y.to_f
          @source_bbox_z = bbox_z.to_f
          @source_scale_x = sanitize_scale_factor(scale_x)
          @source_scale_y = sanitize_scale_factor(scale_y)
          @source_scale_z = sanitize_scale_factor(scale_z)
          @source_anchor_offset = source_anchor_offset_for(definition)
          @last_face = nil
          @last_face_transform = nil
          @hover_target = nil
          @last_valid_hover_target = nil
          @locked_window_target_snapshot = nil
          @apply_target_snapshot = nil
          @hover_valid = false
          @last_logged_hover_face_pid = nil
          @native_window_axes_cache = {}
          @source_window_prototype_state = source_window_state.is_a?(Hash) ? source_window_state : nil
          debug_log(
            'set_source',
            {
              'definition_valid' => !!(definition && definition.valid?),
              'definition_name' => safe_definition_name(definition),
              'bbox_x' => @source_bbox_x,
              'bbox_y' => @source_bbox_y,
              'bbox_z' => @source_bbox_z,
              'scale_x' => @source_scale_x,
              'scale_y' => @source_scale_y,
              'scale_z' => @source_scale_z,
              'source_window_state' => !!@source_window_prototype_state,
              'preview_edges' => Array(@preview_cache['edges']).length,
              'preview_triangles' => Array(@preview_cache['triangles']).length
            }
          )
        end

        def update_params(params)
          @params = params.is_a?(Hash) ? params : {}
          debug_log('update_params', { 'params' => @params })
        end

        def reset_point!
          @locked_origin = nil
          @locked_normal = nil
          @locked_has_face = false
          @locked_face = nil
          @locked_face_transform = nil
          @hover_target = nil
          @last_valid_hover_target = nil
          @locked_window_target_snapshot = nil
          @apply_target_snapshot = nil
          @hover_valid = false
          debug_log('reset_point', debug_snapshot)
          @controller.update_status_prompt
        end

        def transforms_for_apply(frame_override = nil)
          frame = frame_override || current_frame
          unless frame
            debug_log('transforms_for_apply_no_frame', debug_snapshot)
            return []
          end

          transforms = build_transforms(frame, preview: false)
          debug_log(
            'transforms_for_apply',
            debug_snapshot.merge(
              'transform_count' => transforms.length,
              'preview_mode' => false
            )
          )
          transforms
        end

        def capture_current_target!
          if windows_mode?
            target = windows_target_from_preview_cache
            @apply_target_snapshot = duplicate_target_snapshot(target)
            return
          end

          if @hover_face && @hover_face.valid?
            @locked_face = @hover_face
            @locked_face_transform = @hover_face_transform if @hover_face_transform.is_a?(Geom::Transformation)
            @locked_has_face = true
          elsif @last_face && @last_face.valid?
            @locked_face = @last_face
            @locked_face_transform = @last_face_transform if @last_face_transform.is_a?(Geom::Transformation)
            @locked_has_face = true
          else
            target = surface_target_from_last_cursor
            if target && target[:face] && target[:face].valid?
              @locked_face = target[:face]
              @locked_face_transform = target[:transform] if target[:transform].is_a?(Geom::Transformation)
              @locked_has_face = true
            end
          end

          @locked_origin ||= safe_point(@hover_point)
          @locked_normal ||= safe_vector(@hover_normal)
          debug_log('capture_current_target', debug_snapshot)
        rescue StandardError
          # ignore capture failures
        end

        def surface_target_for_apply
          if windows_mode?
            target = windows_target_snapshot_for_apply
            unless target && target[:valid]
              debug_log('surface_target_for_apply_windows_missing_target', debug_snapshot)
              return nil
            end

            face = resolve_snapshot_face(target)
            unless face && face.valid?
              debug_log('surface_target_for_apply_windows_missing_face', debug_snapshot)
              return nil
            end

            entities = entities_for_face(face)
            unless entities.is_a?(Sketchup::Entities)
              debug_log(
                'surface_target_for_apply_windows_bad_entities',
                debug_snapshot.merge(
                  'face_class' => face.class.to_s,
                  'parent_class' => safe_class_name(face.parent),
                  'entities_class' => safe_class_name(entities)
                )
              )
              return nil
            end

            tr = target[:transform]
            unless tr.is_a?(Geom::Transformation)
              debug_log('surface_target_for_apply_windows_bad_transform', debug_snapshot)
              return nil
            end

            result = {
              face: face,
              entities: entities,
              transform: tr,
              source: target[:source].to_s,
              point: safe_point(target[:point]),
              axes: {
                x: safe_vector(target.dig(:axes, :x)),
                y: safe_vector(target.dig(:axes, :y)),
                z: safe_vector(target.dig(:axes, :z))
              },
              hover_valid: true,
              face_pid: target[:face_pid]
            }
            debug_log('surface_target_for_apply_windows', debug_snapshot.merge('target_source' => target[:source].to_s))
            return result
          end

          face = @locked_face || @hover_face || valid_face_or_nil(@last_face)
          if !face || !face.valid?
            target = surface_target_from_last_cursor
            return target if target
          end
          face ||= fallback_face_from_reference
          return nil unless face.is_a?(Sketchup::Face) && face.valid?

          entities = entities_for_face(face)
          return nil unless entities.is_a?(Sketchup::Entities)

          model = Sketchup.active_model
          return nil unless model

          face_transform = face_transform_for(face) || @last_face_transform
          if entities == model.active_entities
            face_transform = model.edit_transform
          elsif face_transform.nil?
            # Fallback for nested hits when input API doesn't expose path transform.
            face_transform = model.edit_transform
          end

          {
            face: face,
            entities: entities,
            transform: face_transform
          }
        rescue StandardError
          nil
        end

        def surface_target_from_preview_state
          face = valid_face_or_nil(@locked_face) || valid_face_or_nil(@hover_face) || valid_face_or_nil(@last_face)
          unless face
            target = surface_target_from_last_cursor
            debug_log(
              'surface_target_from_preview_state_cursor_fallback',
              debug_snapshot.merge('target_valid' => !!(target && target[:face] && target[:face].valid?))
            )
            return target
          end

          entities = entities_for_face(face)
          unless entities.is_a?(Sketchup::Entities)
            debug_log(
              'surface_target_from_preview_state_bad_entities',
              debug_snapshot.merge(
                'face_class' => face.class.to_s,
                'parent_class' => safe_class_name(face.parent),
                'entities_class' => safe_class_name(entities)
              )
            )
            return nil
          end

          model = Sketchup.active_model
          unless model
            debug_log('surface_target_from_preview_state_no_model', debug_snapshot)
            return nil
          end

          face_transform =
            if entities == model.active_entities
              model.edit_transform
            else
              face_transform_for(face) || @locked_face_transform || @hover_face_transform || @last_face_transform || Geom::Transformation.new
            end

          unless face_transform.is_a?(Geom::Transformation)
            debug_log('surface_target_from_preview_state_bad_transform', debug_snapshot)
            return nil
          end

          result = {
            face: face,
            entities: entities,
            transform: face_transform,
            point: safe_point(@locked_origin || @hover_point),
            face_pid: persistent_id_for(face),
            source: 'preview_state'
          }
          debug_log('surface_target_from_preview_state', debug_snapshot.merge('target_source' => 'preview_state'))
          result
        rescue StandardError => error
          debug_log('surface_target_from_preview_state_error', debug_snapshot.merge('message' => error.message.to_s))
          nil
        end

        def windows_apply_diagnostics
          target = windows_target_snapshot_for_apply
          axes = target && target[:axes].is_a?(Hash) ? target[:axes] : {}
          x_axis = safe_vector(axes[:x])
          y_axis = safe_vector(axes[:y])
          z_axis = safe_vector(axes[:z])
          {
            hover_valid: !!@hover_valid,
            hover_face_valid: !!(@hover_face && @hover_face.valid?),
            cached_target: !target.nil?,
            cached_face_valid: !!(target && target[:face] && target[:face].valid?),
            face_pid: target ? target[:face_pid] : nil,
            axis_lengths: {
              x: x_axis ? x_axis.length.to_f : 0.0,
              y: y_axis ? y_axis.length.to_f : 0.0,
              z: z_axis ? z_axis.length.to_f : 0.0
            },
            axis_dots: {
              xy: x_axis && y_axis ? x_axis.dot(y_axis).to_f : 0.0,
              yz: y_axis && z_axis ? y_axis.dot(z_axis).to_f : 0.0,
              xz: x_axis && z_axis ? x_axis.dot(z_axis).to_f : 0.0
            }
          }
        rescue StandardError
          {
            hover_valid: false,
            hover_face_valid: false,
            cached_target: false,
            cached_face_valid: false,
            face_pid: nil,
            axis_lengths: { x: 0.0, y: 0.0, z: 0.0 },
            axis_dots: { xy: 0.0, yz: 0.0, xz: 0.0 }
          }
        end

        def debug_snapshot
          target = @hover_target.is_a?(Hash) ? @hover_target : @last_valid_hover_target
          frame = current_frame rescue nil
          {
            'mode' => @params['mode'].to_s,
            'input_valid' => !!@input_point.valid?,
            'hover_valid' => !!@hover_valid,
            'hover_has_face' => !!@hover_has_face,
            'hover_face_valid' => !!(@hover_face && @hover_face.valid?),
            'last_face_valid' => !!(@last_face && @last_face.valid?),
            'locked_face_valid' => !!(@locked_face && @locked_face.valid?),
            'target_cached' => !target.nil?,
            'target_face_valid' => !!(target && target[:face] && target[:face].valid?),
            'apply_target_cached' => @apply_target_snapshot.is_a?(Hash),
            'frame_available' => !frame.nil?,
            'frame_origin' => frame && frame[:origin] ? point_hash(frame[:origin]) : nil,
            'hover_point' => point_hash(@hover_point),
            'hover_normal' => vector_hash(@hover_normal),
            'last_mouse' => { 'x' => @last_mouse_x, 'y' => @last_mouse_y },
            'source_name' => safe_definition_name(@source_definition),
            'source_valid' => !!(@source_definition && @source_definition.valid?),
            'source_bbox_x' => @source_bbox_x,
            'source_bbox_y' => @source_bbox_y,
            'source_bbox_z' => @source_bbox_z
          }
        rescue StandardError => error
          { 'snapshot_error' => error.message.to_s }
        end

        def point_locked?
          !@locked_origin.nil?
        end

        # Returns current auto-step suggestion (pure step, without seam) in millimeters.
        def suggested_auto_step_mm
          frame = current_frame
          return nil unless frame

          step_x, step_y = auto_step_base_lengths(frame)
          {
            'step_x_mm' => step_x.respond_to?(:to_mm) ? step_x.to_mm.to_f.round(2) : step_x.to_f,
            'step_y_mm' => step_y.respond_to?(:to_mm) ? step_y.to_mm.to_f.round(2) : step_y.to_f
          }
        rescue StandardError
          nil
        end

        private

        def empty_preview_cache
          {
            'edges' => [],
            'triangles' => [],
            'edge_segments' => 0,
            'triangle_count' => 0
          }
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

            @hover_point = point || @input_point.position
            @hover_face = face
            @hover_face_transform = face ? face_transform : nil
            if face && face.valid?
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

          if windows_mode?
            if @hover_has_face && @hover_face && @hover_face.valid?
              resolved_transform = resolve_face_transform_for_hover(@hover_face, @hover_face_transform)
              @hover_face_transform = resolved_transform if resolved_transform.is_a?(Geom::Transformation)
              update_windows_hover_target(@hover_face, @hover_face_transform, @hover_point)
            else
              @hover_valid = false
              @hover_target = nil
            end
          else
            @hover_valid = false
            @hover_target = nil
          end
        end

        def lock_current_hover
          if windows_mode? && @hover_target.is_a?(Hash)
            @locked_window_target_snapshot = duplicate_target_snapshot(@hover_target)
            @apply_target_snapshot = duplicate_target_snapshot(@hover_target)
          end
          @locked_origin = safe_point(@hover_point)
          @locked_normal = safe_vector(@hover_normal)
          @locked_has_face = !!@hover_has_face
          if @hover_has_face
            @locked_face = @hover_face
            @locked_face_transform = @hover_face_transform
          end
        end

        def current_reference
          if @locked_origin
            [@locked_origin, @locked_normal || Z_AXIS, @locked_has_face]
          else
            [safe_point(@hover_point), safe_vector(@hover_normal) || Z_AXIS, @hover_has_face]
          end
        end

        def current_frame
          if windows_mode?
            target = current_windows_preview_target
            return nil unless target

            return current_frame_from_windows_target(target)
          end

          origin, normal_hint, has_face = current_reference
          return nil unless origin

          mode = orientation_mode
          normal = resolve_frame_normal(mode, normal_hint, has_face)
          normal = safe_vector(normal) || Z_AXIS
          u_axis, v_axis, normal = base_axes_for_mode(normal)
          layout_rotation = layout_rotation_radians
          if layout_rotation.abs > EPS
            rotation = Geom::Transformation.rotation(ORIGIN, normal, layout_rotation)
            u_axis = safe_vector(u_axis.transform(rotation)) || u_axis
            v_axis = safe_vector(v_axis.transform(rotation)) || v_axis
          end

          {
            origin: origin,
            u_axis: u_axis,
            v_axis: v_axis,
            layout_v_axis: layout_v_axis(v_axis),
            normal: normal,
            orientation_mode: mode
          }
        end

        def windows_frame_for_apply(target = nil)
          snapshot = target || windows_target_snapshot_for_apply
          return nil unless snapshot

          current_frame_from_windows_target(snapshot)
        rescue StandardError
          nil
        end

        def current_frame_from_windows_target(target)
          axes = target[:axes].is_a?(Hash) ? target[:axes] : {}
          origin = safe_point(target[:point])
          base_transform = target[:base_transform].is_a?(Geom::Transformation) ? target[:base_transform] : nil
          x_axis = safe_vector(axes[:x])
          y_axis = safe_vector(axes[:y])
          z_axis = safe_vector(axes[:z])
          return nil unless origin && x_axis && y_axis && z_axis

          {
            origin: origin,
            u_axis: x_axis,
            v_axis: y_axis,
            layout_u_axis: safe_vector(target.dig(:layout_axes, :x)) || x_axis,
            layout_v_axis: layout_v_axis(safe_vector(target.dig(:layout_axes, :y)) || y_axis),
            normal: z_axis,
            base_transform: base_transform,
            orientation_mode: 'plane'
          }
        end

        def build_transforms(frame, preview:)
          count_x = [@params['count_x'].to_i, 1].max
          count_y = [@params['count_y'].to_i, 1].max
          step_x, step_y = step_lengths(frame)
          step_x = 1.mm if step_x <= EPS
          step_y = 1.mm if step_y <= EPS
          seam_x = [@params['seam_x_mm'].to_f, 0.0].max.mm
          seam_y = [@params['seam_y_mm'].to_f, 0.0].max.mm
          pitch_x = step_x + seam_x
          pitch_y = step_y + seam_y

          origin = frame[:origin]
          u_axis = frame[:u_axis]
          layout_u_axis = frame[:layout_u_axis] || u_axis
          v_axis = frame[:v_axis]
          layout_v_axis = frame[:layout_v_axis] || v_axis
          normal = frame[:normal]
          mode = @params['mode'].to_s
          bond = @params['brick_bond'].to_s
          brick_rotation = brick_rotation_radians(mode)
          random_quadrant = mode == 'brick' && !!@params['random_quadrant']
          comp_u_axis = u_axis
          comp_v_axis = v_axis
          if brick_rotation.abs > EPS
            rotation = Geom::Transformation.rotation(ORIGIN, normal, brick_rotation)
            comp_u_axis = safe_vector(u_axis.transform(rotation)) || u_axis
            comp_v_axis = safe_vector(v_axis.transform(rotation)) || v_axis
          end

          transforms = []
          scale = Geom::Transformation.scaling(@source_scale_x, @source_scale_y, @source_scale_z)
          count_y.times do |row|
            shift_factor = mode == 'brick' ? row_shift_factor(row, bond) : 0.0
            count_x.times do |col|
              dx = (col + shift_factor) * pitch_x
              dy = row * pitch_y
              point = origin.offset(layout_u_axis, dx).offset(layout_v_axis, dy)
              inst_u = comp_u_axis
              inst_v = comp_v_axis
              if random_quadrant
                angle = preview ? deterministic_angle(col, row) : [0, 90, 180, 270].sample.degrees
                if angle.abs > EPS
                  random_rot = Geom::Transformation.rotation(ORIGIN, normal, angle)
                  inst_u = safe_vector(inst_u.transform(random_rot)) || inst_u
                  inst_v = safe_vector(inst_v.transform(random_rot)) || inst_v
                end
              end
              if windows_mode?
                base_transform = frame[:base_transform]
                if base_transform.is_a?(Geom::Transformation)
                  offset = Geom::Vector3d.new(
                    layout_u_axis.x * dx + layout_v_axis.x * dy,
                    layout_u_axis.y * dx + layout_v_axis.y * dy,
                    layout_u_axis.z * dx + layout_v_axis.z * dy
                  )
                  tr = Geom::Transformation.translation(offset) * base_transform
                else
                  tr = Geom::Transformation.axes(point, inst_u, inst_v, normal)
                  shift = window_anchor_world_shift(tr, point, layout_u_axis, layout_v_axis)
                  tr = Geom::Transformation.translation(shift) * tr if shift
                  tr = tr * scale
                end
              else
                tr = Geom::Transformation.axes(point, inst_u, inst_v, normal)
                tr = tr * Geom::Transformation.translation(@source_anchor_offset)
                tr = tr * scale
              end
              # Log the first element transform only during apply (not preview) for comparison with manual insertion.
              if transforms.empty? && mode == 'windows' && !preview
                o = ORIGIN.transform(tr)
                xu = X_AXIS.transform(tr)
                yv = Y_AXIS.transform(tr)
                zn = Z_AXIS.transform(tr)
                debug_log(
                  'build_transforms_first_window_apply',
                  {
                    'origin' => { 'x' => o.x.round(4), 'y' => o.y.round(4), 'z' => o.z.round(4) },
                    'x_axis_world' => { 'x' => (xu.x - o.x).round(6), 'y' => (xu.y - o.y).round(6), 'z' => (xu.z - o.z).round(6) },
                    'y_axis_world' => { 'x' => (yv.x - o.x).round(6), 'y' => (yv.y - o.y).round(6), 'z' => (yv.z - o.z).round(6) },
                    'z_axis_world' => { 'x' => (zn.x - o.x).round(6), 'y' => (zn.y - o.y).round(6), 'z' => (zn.z - o.z).round(6) }
                  }
                )
              end
              transforms << tr
            end
          end
          transforms
        rescue StandardError
          []
        end

        def step_lengths(frame = nil)
          if @params['auto_step']
            step_x, step_y = auto_step_base_lengths(frame)
            [step_x, step_y]
          else
            step_x = [@params['step_x_mm'].to_f, 1.0].max.mm
            step_y = [@params['step_y_mm'].to_f, 1.0].max.mm
            [step_x, step_y]
          end
        rescue StandardError
          [1000.mm, 1000.mm]
        end

        def auto_step_base_lengths(frame)
          return fallback_auto_step_lengths unless frame && @source_definition && @source_definition.valid?

          corners = scaled_definition_corners
          return fallback_auto_step_lengths if corners.empty?
          corners = remap_corners_for_windows(corners)
          corners = rotated_corners_for_brick(corners)

          base = Geom::Transformation.axes(ORIGIN, frame[:u_axis], frame[:v_axis], frame[:normal])
          world_points = corners.map { |pt| pt.transform(base) }
          x_axis = frame[:layout_u_axis] || frame[:u_axis]
          y_axis = frame[:layout_v_axis] || frame[:v_axis]

          step_x = axis_extent(world_points, x_axis)
          step_y = axis_extent(world_points, y_axis)
          step_x = fallback_auto_step_lengths[0] if step_x <= EPS
          step_y = fallback_auto_step_lengths[1] if step_y <= EPS
          [step_x, step_y]
        rescue StandardError
          fallback_auto_step_lengths
        end

        def fallback_auto_step_lengths
          base_y = @params['vertical_up'] ? @source_bbox_z.to_f : @source_bbox_y.to_f
          [@source_bbox_x.to_f, base_y]
        end

        def row_shift_factor(row, bond)
          case bond
          when 'half'
            row.odd? ? 0.5 : 0.0
          when 'third'
            offsets = [1.0 / 3.0, 2.0 / 3.0, 0.0]
            offsets[row % 3]
          else
            0.0
          end
        end

        def brick_rotation_radians(mode)
          return 0.0 unless mode.to_s == 'brick'

          deg = @params['brick_rotation_deg'].to_i
          return 0.0 unless [0, 90, 180, 270].include?(deg)

          deg.degrees
        rescue StandardError
          0.0
        end

        def rotated_corners_for_brick(corners)
          return corners unless @params['mode'].to_s == 'brick'

          angle = brick_rotation_radians('brick')
          return corners if angle.abs <= EPS

          local_rot = Geom::Transformation.rotation(ORIGIN, Z_AXIS, angle)
          corners.map { |pt| pt.transform(local_rot) }
        rescue StandardError
          corners
        end

        def remap_corners_for_windows(corners)
          return corners unless @params['mode'].to_s == 'windows'
          return corners unless source_window_x_is_vertical?

          corners.map { |pt| Geom::Point3d.new(pt.y, pt.x, pt.z) }
        rescue StandardError
          corners
        end

        def layout_rotation_radians
          return 0.0 unless @params['mode'].to_s == 'brick'

          deg = @params['brick_layout_rotation_deg'].to_i
          return 0.0 unless [0, 90, 180, 270].include?(deg)

          deg.degrees
        rescue StandardError
          0.0
        end

        def deterministic_angle(col, row)
          index = ((col.to_i + 1) * 73_856_093 + (row.to_i + 1) * 19_349_663) % 4
          [0, 90, 180, 270][index].degrees
        end

        def draw_preview(view, transforms)
          edges = Array(@preview_cache['edges'])
          triangles = Array(@preview_cache['triangles'])
          return if edges.empty? && triangles.empty?

          step = preview_sampling_step(transforms.length)
          sampled = []
          transforms.each_with_index do |tr, idx|
            next unless (idx % step).zero?

            sampled << tr
          end
          return if sampled.empty?

          colors = preview_colors
          draw_filled = !triangles.empty? && !simplified_preview?

          if draw_filled
            view.drawing_color = colors[:fill]
            sampled.each do |tr|
              points = transform_points(triangles, tr)
              next if points.empty?

              view.draw(GL_TRIANGLES, points)
            end
          end

          unless edges.empty?
            view.drawing_color = colors[:line]
            sampled.each do |tr|
              points = transform_points(edges, tr)
              next if points.empty?

              view.draw(GL_LINES, points)
            end
          end
        end

        def draw_primary_preview(view, transform)
          return unless transform

          edges = Array(@preview_cache['edges'])
          triangles = Array(@preview_cache['triangles'])
          draw_filled = !triangles.empty? && !simplified_preview?

          if draw_filled
            view.drawing_color = Sketchup::Color.new(82, 136, 255, 76)
            tri_points = transform_points(triangles, transform)
            view.draw(GL_TRIANGLES, tri_points) unless tri_points.empty?
          end

          return if edges.empty?

          begin
            view.line_width = 2
          rescue StandardError
            # Some SU versions can reject line_width changes in specific contexts.
          end
          view.drawing_color = Sketchup::Color.new(36, 92, 255)
          edge_points = transform_points(edges, transform)
          view.draw(GL_LINES, edge_points) unless edge_points.empty?
        ensure
          begin
            view.line_width = 1
          rescue StandardError
            # ignore restore failures
          end
        end

        def transform_points(points, tr)
          points.map { |pt| pt.transform(tr) }
        rescue StandardError
          []
        end

        def preview_colors
          if @params['mode'].to_s == 'brick'
            {
              fill: Sketchup::Color.new(222, 140, 68, 86),
              line: Sketchup::Color.new(161, 88, 24)
            }
          else
            {
              fill: Sketchup::Color.new(82, 168, 211, 82),
              line: Sketchup::Color.new(34, 105, 161)
            }
          end
        end

        def simplified_preview?
          return true if @params['simplify_preview']

          instance_count = [@params['count_x'].to_i, 1].max * [@params['count_y'].to_i, 1].max
          edge_segments = @preview_cache['edge_segments'].to_i
          instance_count > 300 || edge_segments > 50_000
        end

        def preview_sampling_step(instance_count)
          # If preview cache is already reduced to lightweight fallback geometry
          # (controller marks it as truncated), drawing all instances is cheap
          # and avoids confusing "missing" preview items.
          return 1 if @preview_cache['truncated']

          limit = simplified_preview? ? 120 : 320
          return 1 if instance_count <= limit

          (instance_count.to_f / limit.to_f).ceil
        end

        def orientation_mode
          mode = @params['orientation_mode'].to_s
          return mode if %w[auto plane world].include?(mode)

          'auto'
        end

        def layout_v_axis(default_v_axis)
          return default_v_axis if windows_mode?
          return default_v_axis unless @params['vertical_up']

          Z_AXIS
        end

        def resolve_frame_normal(mode, normal_hint, has_face)
          if windows_mode?
            return normal_hint if has_face
            return Z_AXIS
          end

          align_to_normal = !!@params['align_to_normal']
          force_face_normal = opening_source_component? && !!@params['place_on_surface'] && has_face
          case mode
          when 'plane'
            normal_hint
          when 'world'
            Z_AXIS
          else
            has_face && (align_to_normal || force_face_normal) ? normal_hint : Z_AXIS
          end
        end

        def base_axes_for_mode(normal)
          if windows_mode?
            window_axes_from_normal(normal)
          else
            generic_axes_from_normal(normal)
          end
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

        def generic_axes_from_normal(normal)
          z_axis = safe_vector(normal) || Z_AXIS
          x_axis = axis_on_plane(X_AXIS, z_axis)
          x_axis = axis_on_plane(Y_AXIS, z_axis) unless x_axis
          x_axis ||= X_AXIS
          x_axis = safe_vector(x_axis) || X_AXIS
          y_axis = safe_vector(z_axis.cross(x_axis))
          unless y_axis
            y_axis = axis_on_plane(Z_AXIS, z_axis)
            y_axis = axis_on_plane(Y_AXIS, z_axis) unless y_axis
            y_axis ||= Y_AXIS
            y_axis = safe_vector(y_axis) || Y_AXIS
          end
          x_axis = safe_vector(y_axis.cross(z_axis)) || x_axis
          [x_axis, y_axis, z_axis]
        rescue StandardError
          [X_AXIS, Y_AXIS, Z_AXIS]
        end

        def windows_mode?
          @params['mode'].to_s == 'windows'
        end

        def native_window_component_axes(horizontal_axis, vertical_axis, normal_axis)
          if source_window_x_is_vertical?
            x_axis = safe_vector(vertical_axis) || vertical_axis
            y_axis = safe_vector(normal_axis * x_axis) || horizontal_axis
            y_axis = safe_vector(y_axis.reverse) if y_axis && horizontal_axis && y_axis.dot(horizontal_axis) < 0.0
            return [x_axis, y_axis]
          end

          x_axis = safe_vector(horizontal_axis) || horizontal_axis
          y_axis = safe_vector(normal_axis * x_axis) || vertical_axis
          y_axis = safe_vector(y_axis.reverse) if y_axis && vertical_axis && y_axis.dot(vertical_axis) < 0.0
          [x_axis, y_axis]
        rescue StandardError
          [horizontal_axis, vertical_axis]
        end

        def source_window_x_is_vertical?
          x_len, y_len = source_local_xy_lengths
          return false unless x_len && y_len

          x_len > (y_len + EPS)
        rescue StandardError
          false
        end

        def source_local_xy_lengths
          return [nil, nil] unless @source_definition && @source_definition.valid?

          bounds = @source_definition.bounds
          min = bounds.min
          max = bounds.max
          return [nil, nil] unless min && max

          x_len = (max.x.to_f - min.x.to_f).abs * @source_scale_x.to_f.abs
          y_len = (max.y.to_f - min.y.to_f).abs * @source_scale_y.to_f.abs
          [x_len, y_len]
        rescue StandardError
          [nil, nil]
        end

        def base_transform_from_source_window_prototype_state(target_normal, point_world)
          state = @source_window_prototype_state
          return nil unless state.is_a?(Hash)

          source_x = safe_vector(state[:x_axis])
          source_y = safe_vector(state[:y_axis])
          source_z = safe_vector(state[:z_axis])
          source_normal = safe_vector(state[:face_normal])
          target_normal = safe_vector(target_normal)
          point = safe_point(point_world)
          return nil unless source_x && source_y && source_z && source_normal && target_normal && point

          rotation = rotation_transform_between_vectors(source_normal, target_normal)
          return nil unless rotation.is_a?(Geom::Transformation)

          target_x = safe_vector(source_x.transform(rotation))
          target_y = safe_vector(source_y.transform(rotation))
          target_z = safe_vector(source_z.transform(rotation))
          return nil unless target_x && target_y && target_z

          Geom::Transformation.axes(point, target_x, target_y, target_z)
        rescue StandardError
          nil
        end

        def rotation_transform_between_vectors(from_vector, to_vector)
          from = safe_vector(from_vector)
          to = safe_vector(to_vector)
          return Geom::Transformation.new unless from && to

          dot = [[from.dot(to).to_f, 1.0].min, -1.0].max
          axis = safe_vector(from * to)
          if axis
            return Geom::Transformation.rotation(ORIGIN, axis, Math.acos(dot))
          end

          return Geom::Transformation.new if dot >= 0.0

          fallback_axis = axis_on_plane(X_AXIS, from)
          fallback_axis = axis_on_plane(Y_AXIS, from) unless fallback_axis
          fallback_axis = axis_on_plane(Z_AXIS, from) unless fallback_axis
          fallback_axis = safe_vector(fallback_axis) || X_AXIS
          Geom::Transformation.rotation(ORIGIN, fallback_axis, 180.degrees)
        rescue StandardError
          Geom::Transformation.new
        end

        def native_window_base_transform_for_face(face, entities, face_transform, point_world)
          return nil unless windows_mode?
          return nil unless face&.valid? && entities.is_a?(Sketchup::Entities)
          return nil unless @source_definition && @source_definition.valid?
          return nil unless face_transform.is_a?(Geom::Transformation)

          face_key = persistent_id_for(face) || begin
            face.respond_to?(:entityID) ? face.entityID : face.object_id
          rescue StandardError
            face.object_id
          end
          cache_key = [face_key, @source_definition.object_id, entities.object_id]
          cached = @native_window_axes_cache[cache_key]
          if cached.is_a?(Hash) && cached[:x] && cached[:y] && cached[:z]
            world_point = safe_point(point_world)
            return nil unless world_point

            x_axis = safe_vector(cached[:x])
            y_axis = safe_vector(cached[:y])
            z_axis = safe_vector(cached[:z])
            return nil unless x_axis && y_axis && z_axis

            return Geom::Transformation.axes(world_point, x_axis, y_axis, z_axis)
          end

          model = Sketchup.active_model
          return nil unless model

          world_point = safe_point(point_world)
          return nil unless world_point

          local_point = safe_point(world_point.transform(face_transform.inverse))
          return nil unless local_point

          operation_started = false
          native_transform = nil

          model.start_operation('CLB Native Window Probe', true)
          operation_started = true

          probe = entities.add_instance(@source_definition, Geom::Transformation.new(local_point))
          probe.glued_to = face if probe && probe.valid? && probe.respond_to?(:glued_to=)

          if probe && probe.valid?
            world_tr = face_transform * probe.transformation
            x_axis = safe_vector(X_AXIS.transform(world_tr))
            y_axis = safe_vector(Y_AXIS.transform(world_tr))
            z_axis = safe_vector(Z_AXIS.transform(world_tr))
            if x_axis && y_axis && z_axis
              @native_window_axes_cache[cache_key] = { x: x_axis, y: y_axis, z: z_axis }
              native_transform = Geom::Transformation.axes(world_point, x_axis, y_axis, z_axis)
              debug_log(
                'native_window_base_transform_probe',
                {
                  'prototype' => safe_definition_name(@source_definition),
                  'face_key' => face_key,
                  'origin' => point_hash(world_point),
                  'x_axis' => vector_hash(x_axis),
                  'y_axis' => vector_hash(y_axis),
                  'z_axis' => vector_hash(z_axis)
                }
              )
              puts(
                "[CLB][ArrayTool] native_window_base_transform_probe #{{
                  prototype: safe_definition_name(@source_definition),
                  face_key: face_key,
                  origin: point_hash(world_point),
                  x_axis: vector_hash(x_axis),
                  y_axis: vector_hash(y_axis),
                  z_axis: vector_hash(z_axis)
                }.inspect}"
              )
            end
          end

          native_transform
        rescue StandardError => error
          debug_log(
            'native_window_base_transform_probe_failed',
            {
              'prototype' => safe_definition_name(@source_definition),
              'error_class' => error.class.to_s,
              'error' => error.message.to_s
            }
          )
          nil
        ensure
          model.abort_operation if operation_started
        end

        def preview_transforms_debug
          frame = current_frame
          return [] unless frame

          build_transforms(frame, preview: true)
        rescue StandardError
          []
        end

        def current_windows_preview_target
          if @locked_window_target_snapshot.is_a?(Hash)
            return duplicate_target_snapshot(@locked_window_target_snapshot)
          end

          if @hover_valid && @hover_target.is_a?(Hash)
            return duplicate_target_snapshot(@hover_target)
          end

          if @last_valid_hover_target.is_a?(Hash)
            return duplicate_target_snapshot(@last_valid_hover_target)
          end

          runtime_target = windows_target_from_runtime_state
          return runtime_target if runtime_target

          fallback = selected_face_target_snapshot
          return fallback if fallback

          nil
        rescue StandardError
          nil
        end

        def windows_target_snapshot_for_apply
          target = @apply_target_snapshot
          target = @locked_window_target_snapshot unless target.is_a?(Hash)
          target = windows_target_from_preview_cache unless target.is_a?(Hash)
          # Final fallback: rebuild from current hover/last-face state so that
          # clicking Apply immediately after hovering (without prior LMB click) works.
          target = windows_target_from_runtime_state unless target.is_a?(Hash)
          return nil unless target.is_a?(Hash)

          duplicate_target_snapshot(target)
        rescue StandardError
          nil
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
            base_transform: target[:base_transform].is_a?(Geom::Transformation) ? target[:base_transform] : nil,
            layout_axes: {
              x: safe_vector(target.dig(:layout_axes, :x)),
              y: safe_vector(target.dig(:layout_axes, :y))
            },
            axes: {
              x: safe_vector(axes[:x]),
              y: safe_vector(axes[:y]),
              z: safe_vector(axes[:z])
            }
          }
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

          entities = entities_for_face(face)
          return nil unless entities.is_a?(Sketchup::Entities)

          # Use the best available transform for this face.
          # resolve_face_transform_for_hover checks: active_entities → model.edit_transform,
          # cached hover/locked transforms, then falls back to identity.
          tr = resolve_face_transform_for_hover(face, nil)
          return nil unless tr.is_a?(Geom::Transformation)

          point =
            begin
              center = face.bounds.center
              center ? safe_point(center.transform(tr)) : nil
            rescue StandardError
              nil
            end
          build_windows_target_snapshot(face, tr, point, source: 'selected_face')
        rescue StandardError
          nil
        end

        def windows_target_from_preview_cache
          target = nil
          if @locked_window_target_snapshot.is_a?(Hash)
            target = @locked_window_target_snapshot
          elsif @hover_valid && @hover_target.is_a?(Hash)
            target = @hover_target
          elsif @last_valid_hover_target.is_a?(Hash)
            target = @last_valid_hover_target
          end
          return nil unless target

          duplicate_target_snapshot(target)
        rescue StandardError
          nil
        end

        def windows_target_from_runtime_state
          face = nil
          face_transform = nil

          if @hover_face && @hover_face.valid?
            face = @hover_face
            face_transform = @hover_face_transform
          elsif @last_face && @last_face.valid?
            face = @last_face
            face_transform = @last_face_transform
          end
          return nil unless face && face.valid?

          tr = resolve_face_transform_for_hover(face, face_transform)
          point = safe_point(@hover_point)
          build_windows_target_snapshot(face, tr, point, source: 'runtime')
        rescue StandardError
          nil
        end

        def build_windows_target_snapshot(face, face_transform, point_world, source: 'runtime')
          return nil unless face && face.valid?

          face_transform = resolve_face_transform_for_hover(face, face_transform)
          return nil unless face_transform.is_a?(Geom::Transformation)

          raw_normal = safe_vector(face.normal.transform(face_transform))
          return nil unless raw_normal

          # Ensure the face normal points toward the camera/viewpoint.
          # This handles reversed faces (front face pointing inward), which would cause
          # a 180° placement error. SketchUp's native component insertion also places on
          # the side the user is looking from, regardless of face orientation in the model.
          normal = ensure_normal_toward_camera(raw_normal, safe_point(point_world))
          normal_was_flipped = normal.dot(raw_normal) < 0

          layout_x_axis, layout_y_axis, _layout_z_axis = window_axes_from_normal(normal)
          layout_x_axis = safe_vector(layout_x_axis)
          layout_y_axis = safe_vector(layout_y_axis)
          return nil unless layout_x_axis && layout_y_axis

          # Log axes for non-hover sources, AND for hover mode when the face changes.
          # Use entityID as the throttle key (always available for valid SketchUp entities;
          # persistent_id can return 0 for some faces making it unusable as a key).
          face_eid_now = begin
            face.respond_to?(:entityID) ? face.entityID : face.object_id
          rescue StandardError
            nil
          end
          should_log = source.to_s != 'hover_preview' ||
                       face_eid_now != @last_logged_hover_face_pid
          if should_log
            @last_logged_hover_face_pid = face_eid_now
            debug_log(
              'window_axes_computed',
              {
                'prototype' => safe_definition_name(@source_definition),
                'source' => source.to_s,
                'face_normal_raw' => { 'x' => raw_normal.x.round(6), 'y' => raw_normal.y.round(6), 'z' => raw_normal.z.round(6) },
                'normal_flipped' => normal_was_flipped,
                'face_normal_world' => { 'x' => normal.x.round(6), 'y' => normal.y.round(6), 'z' => normal.z.round(6) },
                 'layout_x_axis' => { 'x' => layout_x_axis.x.round(6), 'y' => layout_x_axis.y.round(6), 'z' => layout_x_axis.z.round(6) },
                 'layout_y_axis' => { 'x' => layout_y_axis.x.round(6), 'y' => layout_y_axis.y.round(6), 'z' => layout_y_axis.z.round(6) }
               }
             )
             puts(
               "[CLB][ArrayTool] window_axes_computed #{{
                prototype: safe_definition_name(@source_definition),
                source: source.to_s,
                face_normal_raw: vector_hash(raw_normal),
                normal_flipped: normal_was_flipped,
                face_normal_world: vector_hash(normal),
                 layout_x_axis: vector_hash(layout_x_axis),
                 layout_y_axis: vector_hash(layout_y_axis)
               }.inspect}"
             )
           end

          entities = entities_for_face(face)
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

          point = project_point_to_face_plane(point, face, face_transform, normal) || point

          native_base_transform = base_transform_from_source_window_prototype_state(normal, point)
          if native_base_transform.is_a?(Geom::Transformation)
            native_base_transform = native_base_transform * Geom::Transformation.scaling(@source_scale_x, @source_scale_y, @source_scale_z)
            shift = window_anchor_world_shift(native_base_transform, point, layout_x_axis, layout_y_axis)
            native_base_transform = Geom::Transformation.translation(shift) * native_base_transform if shift
          end

          x_axis = safe_vector(native_base_transform && X_AXIS.transform(native_base_transform))
          y_axis = safe_vector(native_base_transform && Y_AXIS.transform(native_base_transform))
          z_axis = safe_vector(native_base_transform && Z_AXIS.transform(native_base_transform))

          unless x_axis && y_axis && z_axis
            x_axis, y_axis, z_axis = window_axes_from_normal(normal)
            x_axis = safe_vector(x_axis)
            y_axis = safe_vector(y_axis)
            z_axis = safe_vector(z_axis)
          end
          return nil unless x_axis && y_axis && z_axis

          duplicate_target_snapshot(
            {
              valid: true,
              face: face,
              face_pid: persistent_id_for(face),
              source: source.to_s,
              point: point,
              entities: entities,
              transform: face_transform,
              base_transform: native_base_transform,
              layout_axes: { x: layout_x_axis, y: layout_y_axis },
              axes: { x: x_axis, y: y_axis, z: z_axis }
            }
          )
        rescue StandardError
          nil
        end

        def persistent_id_for(entity)
          return nil unless entity && entity.valid?
          return nil unless entity.respond_to?(:persistent_id)

          pid = entity.persistent_id.to_i
          pid.positive? ? pid : nil
        rescue StandardError
          nil
        end

        def resolve_snapshot_face(snapshot)
          return nil unless snapshot.is_a?(Hash)

          face = snapshot[:face]
          return face if face && face.valid?

          pid = snapshot[:face_pid].to_i
          entities = snapshot[:entities]
          return nil unless pid.positive? && entities.is_a?(Sketchup::Entities)

          face = entities.grep(Sketchup::Face).find do |candidate|
            next false unless candidate.valid?
            next false unless candidate.respond_to?(:persistent_id)

            candidate.persistent_id.to_i == pid
          rescue StandardError
            false
          end
          face
        rescue StandardError
          nil
        end

        def orthonormal_axes_for_face(face, face_transform)
          return nil unless face && face.valid?
          face_transform = resolve_face_transform_for_hover(face, face_transform)
          return nil unless face_transform.is_a?(Geom::Transformation)

          z_axis = safe_vector(face.normal.transform(face_transform))
          return nil unless z_axis

          y_axis = projected_axis_on_plane(Z_AXIS, z_axis)
          y_axis = projected_axis_on_plane(X_AXIS, z_axis) unless y_axis
          y_axis = projected_axis_on_plane(Y_AXIS, z_axis) unless y_axis
          return nil unless y_axis

          x_axis = safe_vector(y_axis.cross(z_axis))
          x_axis = projected_axis_on_plane(X_AXIS, z_axis) unless x_axis
          x_axis = projected_axis_on_plane(Y_AXIS, z_axis) unless x_axis
          return nil unless x_axis

          # Re-orthonormalize to prevent shear/flattening on YZ/ZX and sloped faces.
          y_axis = safe_vector(z_axis.cross(x_axis))
          return nil unless y_axis
          x_axis = safe_vector(y_axis.cross(z_axis))
          return nil unless x_axis

          xy = x_axis.dot(y_axis).abs
          yz = y_axis.dot(z_axis).abs
          xz = x_axis.dot(z_axis).abs
          return nil if xy > 1.0e-4 || yz > 1.0e-4 || xz > 1.0e-4

          {
            x: x_axis,
            y: y_axis,
            z: z_axis
          }
        rescue StandardError
          nil
        end

        def projected_axis_on_plane(axis, normal)
          axis_on_plane(axis, normal)
        rescue StandardError
          nil
        end

        def resolve_face_transform_for_hover(face, candidate_transform)
          return candidate_transform if candidate_transform.is_a?(Geom::Transformation)
          return nil unless face && face.valid?

          model = Sketchup.active_model
          return Geom::Transformation.new unless model

          if entities_for_face(face) == model.active_entities
            return model.edit_transform
          end

          if @last_face && face.equal?(@last_face) && @last_face_transform.is_a?(Geom::Transformation)
            return @last_face_transform
          end
          if @hover_face && face.equal?(@hover_face) && @hover_face_transform.is_a?(Geom::Transformation)
            return @hover_face_transform
          end
          if @locked_face && face.equal?(@locked_face) && @locked_face_transform.is_a?(Geom::Transformation)
            return @locked_face_transform
          end

          Geom::Transformation.new
        rescue StandardError
          Geom::Transformation.new
        end

        def project_point_to_face_plane(point, face, face_transform, normal)
          return nil unless point
          return nil unless face && face.valid?
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

        # Ensures the given world-space normal points toward the camera eye.
        # Reverses the normal if it points away from the viewpoint.
        # This corrects for reversed faces in the model (front face = interior side),
        # which would otherwise cause a 180° placement error for the window.
        def ensure_normal_toward_camera(normal, face_point)
          return normal unless normal && face_point

          model = Sketchup.active_model
          return normal unless model

          view = model.active_view
          return normal unless view

          eye = begin
            safe_point(view.camera.eye)
          rescue StandardError
            nil
          end
          return normal unless eye

          to_eye = eye - face_point
          return normal if to_eye.length < 1.0

          normal.dot(to_eye) < 0 ? normal.reverse : normal
        rescue StandardError
          normal
        end

        def axis_on_plane(vector, normal)
          projected = vector - normal * vector.dot(normal)
          safe_vector(projected)
        rescue StandardError
          nil
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

          ray = view.pickray(x, y)
          hit = model.raytest(ray, false)
          return [nil, nil, nil, nil] unless hit && hit.is_a?(Array) && hit.length == 2

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
          if !face && edge && edge.valid?
            face = edge.faces.find(&:valid?)
          end
          if face && face.valid? && entities_for_face(face) == model.active_entities
            tr = model.edit_transform
          end
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
          return model.edit_transform if entities_for_face(face) == model.active_entities

          nil
        rescue StandardError
          nil
        end

        def face_transform_for(face)
          return @locked_face_transform if face.equal?(@locked_face)
          return @hover_face_transform if face.equal?(@hover_face)

          nil
        rescue StandardError
          nil
        end

        def valid_face_or_nil(face)
          return nil unless face.is_a?(Sketchup::Face) && face.valid?

          face
        rescue StandardError
          nil
        end

        def fallback_face_from_reference
          origin, normal, _has_face = current_reference
          return nil unless origin && normal

          model = Sketchup.active_model
          return nil unless model

          hit = model.raytest([origin.offset(normal, 1.mm), normal.reverse], false)
          hit ||= model.raytest([origin.offset(normal.reverse, 1.mm), normal], false)
          return nil unless hit && hit.is_a?(Array) && hit.length == 2

          path = hit[1]
          return nil unless path.is_a?(Array)

          tr = Geom::Transformation.new
          face = nil
          path.each do |entry|
            if entry.is_a?(Sketchup::Face)
              face = entry
              break
            end
            tr = tr * entry.transformation if entry.respond_to?(:transformation)
          end
          return nil unless face && face.valid?

          @last_face = face
          @last_face_transform = tr
          face
        rescue StandardError
          nil
        end

        def surface_target_from_last_cursor
          return nil unless @last_mouse_x && @last_mouse_y

          model = Sketchup.active_model
          return nil unless model
          view = model.active_view
          return nil unless view

          face, _point, _normal, tr = raycast_face_from_view(view, @last_mouse_x, @last_mouse_y)
          return nil unless face && face.valid?

          entities = entities_for_face(face)
          return nil unless entities.is_a?(Sketchup::Entities)

          if entities == model.active_entities
            tr = model.edit_transform
          elsif !tr.is_a?(Geom::Transformation)
            tr = model.edit_transform
          end

          @last_face = face
          @last_face_transform = tr

          {
            face: face,
            entities: entities,
            transform: tr
          }
        rescue StandardError
          nil
        end

        def input_face(input_point)
          return nil unless input_point&.valid?
          return nil unless input_point.respond_to?(:face)

          face = input_point.face
          return nil unless face
          return nil unless face.is_a?(Sketchup::Face) && face.valid?

          face
        rescue StandardError
          nil
        end

        def project_ray_to_ground(ray)
          return ORIGIN unless ray && ray.length == 2

          origin = ray[0]
          direction = ray[1]
          return origin if direction.z.abs < EPS

          t = -origin.z / direction.z
          origin.offset(direction, t)
        rescue StandardError
          ORIGIN
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

        def source_anchor_offset_for(definition)
          return Geom::Vector3d.new(0, 0, 0) unless definition && definition.valid?

          bounds = definition.bounds
          min = bounds.min
          max = bounds.max
          return Geom::Vector3d.new(0, 0, 0) unless min && max

          behavior = definition.respond_to?(:behavior) ? definition.behavior : nil
          cuts_opening = behavior && behavior.respond_to?(:cuts_opening?) ? !!behavior.cuts_opening? : false
          gluable = behavior && behavior.respond_to?(:is2d?) ? !!behavior.is2d? : false
          # Opening components must keep author-defined glue/cut plane at local Z=0.
          return Geom::Vector3d.new(0, 0, 0) if cuts_opening

          if gluable
            # For non-cutting gluable elements keep XY insertion point,
            # but shift local Z to sit on the picked face.
            Geom::Vector3d.new(0, 0, -min.z)
          else
            Geom::Vector3d.new(0, 0, 0)
          end
        rescue StandardError
          Geom::Vector3d.new(0, 0, 0)
        end

        def opening_source_component?
          return false unless @source_definition && @source_definition.valid?
          return false unless @source_definition.respond_to?(:behavior)

          behavior = @source_definition.behavior
          return false unless behavior && behavior.respond_to?(:cuts_opening?)

          !!behavior.cuts_opening?
        rescue StandardError
          false
        end

        def sanitize_scale_factor(value)
          v = value.to_f
          v = 1.0 if v <= EPS
          v
        rescue StandardError
          1.0
        end

        def scaled_definition_corners
          return [] unless @source_definition && @source_definition.valid?

          corners = definition_bounds_corners(@source_definition.bounds)
          return [] if corners.empty?

          corners.map do |pt|
            Geom::Point3d.new(
              pt.x * @source_scale_x,
              pt.y * @source_scale_y,
              pt.z * @source_scale_z
            )
          end
        rescue StandardError
          []
        end

        def axis_extent(points, axis)
          dir = safe_vector(axis)
          return 0.0 unless dir && points.is_a?(Array) && !points.empty?

          values = points.map { |pt| pt.x * dir.x + pt.y * dir.y + pt.z * dir.z }
          values.max.to_f - values.min.to_f
        rescue StandardError
          0.0
        end

        def source_depth_axis_for_windows
          x = @source_bbox_x.to_f.abs
          y = @source_bbox_y.to_f.abs
          z = @source_bbox_z.to_f.abs
          return :x if x <= y && x <= z
          return :y if y <= x && y <= z

          :z
        rescue StandardError
          :z
        end

        def window_anchor_world_shift(base_transform, anchor_point, horizontal_axis, vertical_axis)
          return nil unless base_transform.is_a?(Geom::Transformation)

          corners = scaled_definition_corners
          return nil if corners.empty?

          corners = remap_corners_for_windows(corners)
          world_points = corners.map { |pt| pt.transform(base_transform) }
          return nil if world_points.empty?

          u_dir = safe_vector(horizontal_axis)
          v_dir = safe_vector(vertical_axis)
          anchor = safe_point(anchor_point)
          return nil unless u_dir && v_dir && anchor

          anchor_u = anchor.dot(u_dir).to_f
          anchor_v = anchor.dot(v_dir).to_f
          min_u = world_points.map { |pt| pt.dot(u_dir).to_f }.min.to_f
          min_v = world_points.map { |pt| pt.dot(v_dir).to_f }.min.to_f

          du = anchor_u - min_u
          dv = anchor_v - min_v
          return nil if du.abs <= EPS && dv.abs <= EPS

          Geom::Vector3d.new(
            u_dir.x * du + v_dir.x * dv,
            u_dir.y * du + v_dir.y * dv,
            u_dir.z * du + v_dir.z * dv
          )
        rescue StandardError
          nil
        end

        def entities_for_face(face)
          return nil unless face.is_a?(Sketchup::Face) && face.valid?

          parent = face.parent
          return parent if parent.is_a?(Sketchup::Entities)
          return parent.entities if parent.respond_to?(:entities)

          nil
        rescue StandardError
          nil
        end

        def safe_class_name(object)
          return '' unless object

          object.class.to_s
        rescue StandardError
          ''
        end

        def debug_hover_state(event_name, x:, y:)
          signature = [
            windows_mode? ? 'windows' : @params['mode'].to_s,
            @hover_valid ? 1 : 0,
            @hover_has_face ? 1 : 0,
            @hover_face && @hover_face.valid? ? persistent_id_for(@hover_face) : 0,
            @last_face && @last_face.valid? ? persistent_id_for(@last_face) : 0,
            @hover_target.is_a?(Hash) ? @hover_target[:source].to_s : '',
            @apply_target_snapshot.is_a?(Hash) ? 1 : 0,
            x.to_i,
            y.to_i
          ].join(':')
          now = Time.now.to_f
          return if signature == @debug_last_hover_signature && (now - @debug_last_hover_log_at) < 0.35

          @debug_last_hover_signature = signature
          @debug_last_hover_log_at = now
          debug_log(event_name, debug_snapshot.merge('x' => x, 'y' => y))
        rescue StandardError
          nil
        end

        def debug_log(event_name, payload = nil)
          Logger.debug("ArrayTool #{event_name}", payload)
        rescue StandardError
          nil
        end

        def point_hash(point)
          return nil unless point
          { 'x' => point.x.to_f, 'y' => point.y.to_f, 'z' => point.z.to_f }
        rescue StandardError
          nil
        end

        def vector_hash(vector)
          return nil unless vector
          { 'x' => vector.x.to_f, 'y' => vector.y.to_f, 'z' => vector.z.to_f }
        rescue StandardError
          nil
        end

        def safe_definition_name(definition)
          return '' unless definition
          name = definition.respond_to?(:name) ? definition.name.to_s : ''
          name.to_s
        rescue StandardError
          ''
        end

        public :windows_frame_for_apply

      end
    end
  end
end
