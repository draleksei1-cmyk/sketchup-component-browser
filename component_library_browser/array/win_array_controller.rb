require 'json'
require 'securerandom'

module Drale
  module ComponentLibraryBrowser
    module ArrayLayout
      class WinArrayController
        PALETTE_TITLE = 'Раскладка окон'.freeze
        PALETTE_KEY = 'DraleComponentLibraryWinArrayPalette'.freeze
        ARRAY_ATTR_DICTIONARY = 'ComponentLibraryBrowser'.freeze
        ARRAY_ATTR_ID_KEY = 'array_id'.freeze
        MAX_PREVIEW_EDGE_PTS = 120_000
        MAX_PREVIEW_TRI_PTS = 180_000

        def initialize(host)
          @host = host
          @palette = nil
          @tool = nil
          @source_definition = nil
          @source_name = 'Не выбран'
          @source_item_id = nil
          @source_path = nil
          @source_bbox_x = 0.0
          @source_bbox_y = 0.0
          @source_scale_x = 1.0
          @source_scale_y = 1.0
          @source_scale_z = 1.0
          @preview_cache = empty_preview_cache
          session_params =
            if @host.respond_to?(:read_win_array_session_params)
              @host.read_win_array_session_params
            end
          @params = normalize_params(session_params || default_params)
          @session_active = false
          @closing = false
          @non_cutting_warning_shown = false
        end

        def launch
          reset_source!
          ensure_palette!
          show_palette!
          ensure_tool!
          @tool.reset_point!
          activate_tool!
          @session_active = true
          @non_cutting_warning_shown = false
          @host.set_array_tool_active(true) if @host.respond_to?(:set_array_tool_active)
          push_palette_state
          update_status_prompt
          Logger.debug('WinArrayController launch', { 'params' => @params, 'log_path' => Logger.file_path })
          true
        rescue StandardError => error
          report_error('Запуск раскладки окон', error)
          false
        end

        def select_source_model
          return false unless Sketchup.active_model

          clear_library_pick_mode
          pick_tool = Tools::PickSourceTool.new(
            on_pick: proc do |definition, display_name, entity, world_transform|
              begin
                set_source_definition(
                  definition,
                  display_name: display_name,
                  source: 'model',
                  source_entity: entity,
                  source_transform: world_transform
                )
              ensure
                activate_tool_deferred!
              end
            end,
            on_cancel: proc do
              activate_tool_deferred!
              update_status_prompt
            end
          )
          Sketchup.active_model.select_tool(pick_tool)
          Sketchup.status_text = 'Пипетка: выберите оконный компонент в модели. Esc - отмена.'
          true
        rescue StandardError => error
          report_error('Выбор прототипа пипеткой', error)
          false
        end

        def select_source_library
          return false unless @host.respond_to?(:open_library)

          @host.open_library
          set_library_pick_mode('Выберите оконный компонент в библиотеке')
          Sketchup.status_text = 'Библиотека: выберите оконный компонент для вставки.'
          true
        rescue StandardError => error
          report_error('Выбор прототипа из библиотеки', error)
          false
        end

        def pick_from_library(item_id)
          storage = array_storage
          return false unless storage

          item = storage.item_by_id(item_id.to_s)
          unless item
            UI.messagebox('Элемент библиотеки не найден.')
            return false
          end

          skp_path = FS.to_full_path(storage.lib_root, item['skp_rel_path'])
          unless File.file?(skp_path)
            UI.messagebox("Файл компонента не найден:\n#{skp_path}")
            return false
          end

          model = Sketchup.active_model
          definition = Compat.load_definition_from_file(
            skp_path,
            definitions: model.definitions,
            notify_user: true,
            context: 'win_place_pick_library',
            library_path: storage.lib_root
          )
          definition = @host.send(:ensure_component_definition_for_insert, definition) if @host.respond_to?(:send)

          set_source_definition(
            definition,
            display_name: item['name'].to_s.strip.empty? ? FS.display_name_from_skp(skp_path) : item['name'].to_s,
            source: 'library',
            item_id: item['id'],
            source_path: skp_path
          )
          clear_library_pick_mode
          activate_tool_deferred!
          true
        rescue StandardError => error
          report_error('Выбор прототипа из библиотеки', error)
          false
        end

        def update_params(payload = nil)
          data = parse_payload(payload)
          @params = normalize_params(@params.merge(data))
          persist_session_params
          @tool&.update_params(tool_params_for_array_tool)
          push_palette_state
          invalidate_view
          activate_tool_deferred! if source_ready?
          Logger.debug('WinArrayController update_params', { 'params' => @params, 'tool_params' => tool_params_for_array_tool })
          true
        rescue StandardError => error
          report_error('Обновление параметров раскладки окон', error)
          false
        end

        def apply
          unless source_ready?
            UI.messagebox('Сначала выберите оконный компонент.')
            return false
          end

          ensure_tool!
          @tool.capture_current_target! if @tool.respond_to?(:capture_current_target!)

          target = @tool.surface_target_for_apply
          if (!target || !target[:face] || !target[:face].valid?) && @tool.respond_to?(:surface_target_from_preview_state)
            target = @tool.surface_target_from_preview_state
          end
          Logger.debug(
            'WinArrayController apply target',
            {
              'params' => @params,
              'tool_snapshot' => @tool&.debug_snapshot,
              'target_valid' => !!(target && target[:face] && target[:face].valid?)
            }
          )
          unless target && target[:face]&.valid?
            activate_tool_deferred!
            UI.messagebox('Наведите курсор на плоскость стены или щелкните по ней, чтобы появился предпросмотр.')
            return false
          end

          face = target[:face]
          entities = target[:entities]
          basis_tr = target[:transform]
          face_pid = if face.respond_to?(:persistent_id) then face.persistent_id.to_i else 0 end
          transforms = @tool.transforms_for_apply
          preview_transforms = @tool.respond_to?(:preview_transforms_debug) ? @tool.preview_transforms_debug : []
          Logger.debug('WinArrayController apply transforms', { 'count' => transforms.length, 'tool_snapshot' => @tool&.debug_snapshot })
          debug_console(
            'apply_transforms',
            {
              'prototype' => @source_name,
              'target_face_normal' => vector_hash_for_debug(target.dig(:axes, :z)),
              'preview_transform' => transform_hash_for_debug(preview_transforms.first),
              'apply_transform' => transform_hash_for_debug(transforms.first),
              'delta' => transform_delta_hash(preview_transforms.first, transforms.first)
            }
          )
          if transforms.empty?
            UI.messagebox('Не удалось построить предварительную раскладку.')
            return false
          end

          unless valid_window_target?(face, entities, basis_tr)
            UI.messagebox('Не удалось определить плоскость вставки.')
            return false
          end

          model = Sketchup.active_model
          return false unless model

          opening = opening_component?(@source_definition)
          warn_non_cutting_once unless opening

          operation_started = false
          array_id = next_array_id
          inserted = 0

          model.start_operation('Раскладка окон', true)
          operation_started = true

          transforms.each do |world_tr|
            current_face = face.valid? ? face : resolve_face_by_pid(entities, face_pid)
            raise 'Целевая грань недоступна.' unless current_face&.valid?

            instance = add_instance_in_entities(entities, basis_tr, world_tr)
            tag_array_entity(instance, array_id)

            glued = glue_instance_to_face(instance, current_face)
            debug_console('glue_status', { 'prototype' => @source_name, 'glued' => glued, 'glued_to' => instance.respond_to?(:glued_to) ? !!instance.glued_to : nil })
            if opening && !glued
              raise 'Не удалось приклеить прорезной компонент к плоскости.'
            end

            inserted += 1
          end

          model.commit_operation
          operation_started = false

          Logger.info('Раскладка окон применена', { 'array_id' => array_id, 'instances' => inserted })
          close_session!
          true
        rescue StandardError => error
          Sketchup.active_model&.abort_operation if operation_started
          report_error('Применение раскладки окон', error)
          false
        end

        def cancel
          close_session!
          true
        rescue StandardError => error
          report_error('Отмена раскладки окон', error)
          false
        end

        def reset_point
          ensure_tool!
          @tool.reset_point!
          invalidate_view
          true
        rescue StandardError => error
          report_error('Сброс точки', error)
          false
        end

        def update_status_prompt
          if source_ready?
            Sketchup.status_text = 'Раскладка окон: наведите курсор на плоскость, ЛКМ фиксирует точку, Enter или Применить вставляет.'
          else
            Sketchup.status_text = 'Раскладка окон: выберите оконный компонент пипеткой или из библиотеки.'
          end
        rescue StandardError
          nil
        end

        def source_ready?
          @source_definition&.valid?
        rescue StandardError
          false
        end

        def session_active?
          !!@session_active
        end

        private

        def reset_source!
          @source_definition = nil
          @source_name = 'Не выбран'
          @source_item_id = nil
          @source_path = nil
          @source_bbox_x = 0.0
          @source_bbox_y = 0.0
          @source_scale_x = 1.0
          @source_scale_y = 1.0
          @source_scale_z = 1.0
          @preview_cache = empty_preview_cache
          @tool&.set_source(nil, cache: @preview_cache, bbox_x: 0.0, bbox_y: 0.0)
        rescue StandardError
          @source_definition = nil
        end

        def palette_state_hash
          {
            'source_ready' => source_ready?,
            'source_name' => @source_name.to_s,
            'params' => @params
          }
        end

        def ensure_tool!
          return @tool if @tool

          @tool = Tools::ArrayTool.new(self)
          @tool.update_params(tool_params_for_array_tool)
          if source_ready?
            @tool.set_source(
              @source_definition,
              cache: @preview_cache,
              bbox_x: @source_bbox_x,
              bbox_y: @source_bbox_y,
              scale_x: @source_scale_x,
              scale_y: @source_scale_y,
              scale_z: @source_scale_z
            )
          end
          @tool
        end

        def activate_tool!
          model = Sketchup.active_model
          return false unless model

          ensure_tool!
          model.select_tool(@tool)
          true
        rescue StandardError
          false
        end

        def activate_tool_deferred!
          activated_now = activate_tool!
          UI.start_timer(0, false) do
            activate_tool!
            update_status_prompt
          end
          activated_now
        rescue StandardError
          false
        end

        def ensure_palette!
          return if @palette

          @palette = UI::HtmlDialog.new(
            dialog_title: PALETTE_TITLE,
            preferences_key: PALETTE_KEY,
            style: UI::HtmlDialog::STYLE_UTILITY,
            resizable: true,
            width: 860,
            height: 96,
            min_width: 640,
            min_height: 82
          )
          @palette.set_file(File.join(__dir__, '..', 'ui', 'win_array_palette.html'))
          @palette.set_on_closed do
            was_closing = @closing
            @palette = nil
            next if was_closing

            @session_active = false
            clear_library_pick_mode
            @host.set_array_tool_active(false) if @host.respond_to?(:set_array_tool_active)
            Sketchup.active_model&.select_tool(nil)
            Sketchup.status_text = ''
          end
          register_palette_callbacks
        end

        def show_palette!
          return unless @palette

          @palette.show
          @palette.set_position(24, 40) if @palette.respond_to?(:set_position)
        end

        def register_palette_callbacks
          return unless @palette

          @palette.add_action_callback('win_palette_ready') do |_ctx, _payload|
            push_palette_state
            activate_tool_deferred! if @session_active
          end
          @palette.add_action_callback('win_select_source_model') { |_ctx, _payload| select_source_model }
          @palette.add_action_callback('win_select_source_library') { |_ctx, _payload| select_source_library }
          @palette.add_action_callback('win_params_update') { |_ctx, payload| update_params(payload) }
          @palette.add_action_callback('win_apply') { |_ctx, _payload| apply }
          @palette.add_action_callback('win_cancel') { |_ctx, _payload| cancel }
          @palette.add_action_callback('win_reset_point') { |_ctx, _payload| reset_point }
        end

        def push_palette_state
          return unless @palette

          script = "window.WinPalette && window.WinPalette.setState(#{JSON.generate(palette_state_hash)});"
          @palette.execute_script(script)
        rescue StandardError
          nil
        end

        def close_session!
          return if @closing

          @closing = true
          @session_active = false
          clear_library_pick_mode
          @host.set_array_tool_active(false) if @host.respond_to?(:set_array_tool_active)
          close_palette
          Sketchup.active_model&.select_tool(nil)
          Sketchup.status_text = ''
        ensure
          @closing = false
        end

        def close_palette
          return unless @palette

          @palette.close
          @palette = nil
        rescue StandardError
          @palette = nil
        end

        def set_source_definition(definition, display_name:, source:, item_id: nil, source_path: nil, source_entity: nil, source_transform: nil)
          raise ArgumentError, 'Определение компонента невалидно.' unless definition&.valid?

          @source_definition = definition
          @source_name = display_name.to_s.strip
          @source_name = source == 'library' ? 'Элемент библиотеки' : 'Компонент в модели' if @source_name.empty?
          @source_item_id = item_id
          @source_path = source_path

          prepare_definition_for_gluing(@source_definition)

          sx, sy, sz = source_scale_factors(source_entity, source_transform)
          @source_scale_x = sx
          @source_scale_y = sy
          @source_scale_z = sz
          plane_x, plane_y, _thickness = source_plane_dimensions(@source_definition, sx, sy, sz)
          @source_bbox_x = plane_x.to_f
          @source_bbox_y = plane_y.to_f
          @params['step_x_mm'] = length_to_mm(plane_x).round(2)
          @params['step_y_mm'] = length_to_mm(plane_y).round(2)
          @params['axis_spacing_mm'] = @params['step_x_mm']
          @params['floor_height_mm'] = @params['step_y_mm']
          @preview_cache = build_preview_cache(@source_definition)

          ensure_tool!
          @tool.set_source(
            @source_definition,
            cache: @preview_cache,
            bbox_x: @source_bbox_x,
            bbox_y: @source_bbox_y,
            scale_x: @source_scale_x,
            scale_y: @source_scale_y,
            scale_z: @source_scale_z,
            source_window_state: build_source_window_prototype_state(source_entity, source_transform)
          )
          @tool.update_params(tool_params_for_array_tool)
          @tool.reset_point!
          activate_tool! if @session_active
          push_palette_state
          update_status_prompt
          invalidate_view
          Logger.debug(
            'WinArrayController set_source_definition',
            {
              'source' => source.to_s,
              'display_name' => @source_name,
              'definition_name' => definition.respond_to?(:name) ? definition.name.to_s : '',
              'bbox_x' => @source_bbox_x,
              'bbox_y' => @source_bbox_y,
              'scale_x' => @source_scale_x,
              'scale_y' => @source_scale_y,
              'scale_z' => @source_scale_z,
              'params' => @params,
              'tool_params' => tool_params_for_array_tool
            }
          )
          true
        end

        def prepare_definition_for_gluing(definition)
          return unless definition&.valid? && definition.respond_to?(:behavior)

          behavior = definition.behavior
          return unless behavior

          if opening_component?(definition)
            behavior.is2d = true if behavior.respond_to?(:is2d=) && (!behavior.respond_to?(:is2d?) || !behavior.is2d?)
            if behavior.respond_to?(:snapto=) && defined?(SnapTo_Arbitrary)
              behavior.snapto = SnapTo_Arbitrary
            end
          end
        rescue StandardError
          nil
        end

        def opening_component?(definition)
          return false unless definition&.valid? && definition.respond_to?(:behavior)

          behavior = definition.behavior
          behavior.respond_to?(:cuts_opening?) && !!behavior.cuts_opening?
        rescue StandardError
          false
        end

        # Cutting windows can only glue to a real face in the entities context
        # that owns it. This prevents an instance from being added to a parent
        # group/model while trying to cut a face reached through another path.
        def valid_window_target?(face, entities, basis_tr)
          return false unless face&.valid? && entities.is_a?(Sketchup::Entities)
          return false unless basis_tr.is_a?(Geom::Transformation)
          return false unless face.parent.equal?(entities)

          normal = face.normal
          normal && normal.length.to_f > 1.0e-9
        rescue StandardError
          false
        end

        def add_instance_in_entities(entities, basis_tr, world_tr)
          local_tr = Tools::WindowPlacement.local_transform(basis_tr, world_tr)
          entities.add_instance(@source_definition, local_tr)
        end

        def glue_instance_to_face(instance, face)
          return false unless instance&.valid? && face&.valid?
          return false unless instance.respond_to?(:glued_to=)

          instance.glued_to = face
          true
        rescue StandardError
          false
        end

        def resolve_face_by_pid(entities, pid)
          return nil unless pid.to_i.positive? && entities.is_a?(Sketchup::Entities)

          entities.grep(Sketchup::Face).find do |face|
            face.valid? && face.respond_to?(:persistent_id) && face.persistent_id.to_i == pid
          end
        rescue StandardError
          nil
        end

        def tag_array_entity(entity, array_id)
          return unless entity&.valid? && array_id

          entity.set_attribute(ARRAY_ATTR_DICTIONARY, ARRAY_ATTR_ID_KEY, array_id.to_s)
        rescue StandardError
          nil
        end

        def next_array_id
          "#{Time.now.to_i}-#{SecureRandom.hex(4)}"
        rescue StandardError
          Time.now.to_i.to_s
        end

        def warn_non_cutting_once
          return if @non_cutting_warning_shown

          @non_cutting_warning_shown = true
          UI.messagebox('Компонент не имеет режима cuts opening. Он будет вставлен и приклеен, но без прорезания отверстия.')
        rescue StandardError
          nil
        end

        def build_preview_cache(definition)
          edges = []
          triangles = []
          truncated = false
          collect_preview_geometry(definition.entities, Geom::Transformation.new, edges, triangles, depth: 0)

          if edges.length > MAX_PREVIEW_EDGE_PTS || triangles.length > MAX_PREVIEW_TRI_PTS
            truncated = true
            edges = bbox_edges(definition.bounds)
            triangles = []
          end

          {
            'edges' => edges,
            'triangles' => triangles,
            'edge_segments' => edges.length / 2,
            'triangle_count' => triangles.length / 3,
            'truncated' => truncated
          }
        rescue StandardError
          empty_preview_cache
        end

        def collect_preview_geometry(entities, transform, edges, triangles, depth:)
          return if depth > 12
          return if edges.length > MAX_PREVIEW_EDGE_PTS || triangles.length > MAX_PREVIEW_TRI_PTS

          entities.each do |entity|
            case entity
            when Sketchup::Edge
              edges << entity.start.position.transform(transform)
              edges << entity.end.position.transform(transform)
            when Sketchup::Face
              append_face_triangles(entity, transform, triangles)
            when Sketchup::ComponentInstance, Sketchup::Group
              child_tr = transform * entity.transformation
              collect_preview_geometry(entity.definition.entities, child_tr, edges, triangles, depth: depth + 1)
            end
            break if edges.length > MAX_PREVIEW_EDGE_PTS || triangles.length > MAX_PREVIEW_TRI_PTS
          end
        rescue StandardError
          nil
        end

        def append_face_triangles(face, transform, triangles)
          mesh = face.mesh
          points = mesh.points
          mesh.polygons.each do |poly|
            ids = poly.map { |index| index.to_i.abs }.reject(&:zero?)
            next if ids.length < 3

            p0 = points[ids[0] - 1].transform(transform)
            1.upto(ids.length - 2) do |index|
              triangles << p0
              triangles << points[ids[index] - 1].transform(transform)
              triangles << points[ids[index + 1] - 1].transform(transform)
            end
          end
        rescue StandardError
          nil
        end

        def bbox_edges(bounds)
          return [] unless bounds

          min = bounds.min
          max = bounds.max
          p000 = Geom::Point3d.new(min.x, min.y, min.z)
          p100 = Geom::Point3d.new(max.x, min.y, min.z)
          p110 = Geom::Point3d.new(max.x, max.y, min.z)
          p010 = Geom::Point3d.new(min.x, max.y, min.z)
          p001 = Geom::Point3d.new(min.x, min.y, max.z)
          p101 = Geom::Point3d.new(max.x, min.y, max.z)
          p111 = Geom::Point3d.new(max.x, max.y, max.z)
          p011 = Geom::Point3d.new(min.x, max.y, max.z)
          [
            p000, p100, p100, p110, p110, p010, p010, p000,
            p001, p101, p101, p111, p111, p011, p011, p001,
            p000, p001, p100, p101, p110, p111, p010, p011
          ]
        rescue StandardError
          []
        end

        def source_scale_factors(entity, world_transform = nil)
          tr =
            if world_transform.is_a?(Geom::Transformation)
              world_transform
            elsif entity&.respond_to?(:transformation)
              entity.transformation
            end
          return [1.0, 1.0, 1.0] unless tr

          sx = tr.xaxis.length.to_f
          sy = tr.yaxis.length.to_f
          sz = tr.zaxis.length.to_f
          sx = 1.0 if sx <= 0.0
          sy = 1.0 if sy <= 0.0
          sz = 1.0 if sz <= 0.0
          [sx, sy, sz]
        rescue StandardError
          [1.0, 1.0, 1.0]
        end

        def build_source_window_prototype_state(entity, world_transform = nil)
          return nil unless entity.is_a?(Sketchup::ComponentInstance) && entity.valid?

          tr =
            if world_transform.is_a?(Geom::Transformation)
              world_transform
            elsif entity.respond_to?(:transformation)
              entity.transformation
            end
          return nil unless tr.is_a?(Geom::Transformation)

          glued_face = entity.respond_to?(:glued_to) ? entity.glued_to : nil
          return nil unless glued_face.is_a?(Sketchup::Face) && glued_face.valid?

          face_normal = Tools::WindowPlacement.face_normal_in_world(
            glued_face.normal,
            tr,
            entity.transformation
          )
          return nil unless face_normal

          face_up = axis_on_face(face_normal, Z_AXIS)
          face_up = axis_on_face(face_normal, Y_AXIS) unless face_up
          face_up = axis_on_face(face_normal, X_AXIS) unless face_up
          face_up = normalize_vector(face_up) || Y_AXIS
          face_right = normalize_vector(face_up * face_normal)
          face_right = axis_on_face(face_normal, X_AXIS) unless face_right
          face_right = axis_on_face(face_normal, Y_AXIS) unless face_right
          face_right = normalize_vector(face_right) || X_AXIS
          face_up = normalize_vector(face_normal * face_right) || face_up

          face_origin = ORIGIN.transform(tr)
          source_face_frame = Geom::Transformation.axes(face_origin, face_right, face_up, face_normal)
          relative_transform = source_face_frame.inverse * tr

          {
            source_face_x: face_right,
            source_face_y: face_up,
            source_face_z: face_normal,
            source_face_origin: face_origin,
            source_window_transform: tr,
            relative_transform: relative_transform
          }
        rescue StandardError
          nil
        end

        def axis_on_face(normal, axis)
          return nil unless normal && axis

          projected = axis - normal * axis.dot(normal)
          normalize_vector(projected)
        rescue StandardError
          nil
        end

        def normalize_vector(vector)
          return nil unless vector

          v = Geom::Vector3d.new(vector.x, vector.y, vector.z)
          return nil unless v.length > 1.0e-6

          v.normalize
        rescue StandardError
          nil
        end

        def source_plane_dimensions(definition, sx, sy, sz)
          bounds = definition.bounds
          dims = [
            bounds.width * sx,
            bounds.height * sz,
            bounds.depth * sy
          ].sort_by { |value| value.to_f.abs }

          thickness = dims[0]
          plane_dims = dims[1, 2].sort.reverse
          plane_x = plane_dims[0] || bounds.width * sx
          plane_y = plane_dims[1] || bounds.height * sz
          [plane_x, plane_y, thickness]
        rescue StandardError
          [definition.bounds.width * sx, definition.bounds.height * sz, definition.bounds.depth * sy]
        end

        def length_to_mm(value)
          value.respond_to?(:to_mm) ? value.to_mm.to_f : value.to_f
        rescue StandardError
          value.to_f
        end

        def normalize_params(raw)
          data = raw.is_a?(Hash) ? raw : {}
          axis_spacing = normalize_float(data['axis_spacing_mm'], nil)
          floor_height = normalize_float(data['floor_height_mm'], nil)
          step_x = normalize_float(data['step_x_mm'], 1.0)
          step_y = normalize_float(data['step_y_mm'], 1.0)
          axis_spacing ||= step_x
          floor_height ||= step_y
          {
            'count_x' => [[data['count_x'].to_i, 1].max, 500].min,
            'count_y' => [[data['count_y'].to_i, 1].max, 500].min,
            # The palette still submits the established names. They are the
            # canonical array pitches, not discarded compatibility metadata.
            'axis_spacing_mm' => axis_spacing,
            'floor_height_mm' => floor_height,
            'auto_step' => data.key?('auto_step') ? !!data['auto_step'] : false,
            'step_x_mm' => axis_spacing,
            'step_y_mm' => floor_height,
            'seam_x_mm' => normalize_float(data['seam_x_mm'], 0.0),
            'seam_y_mm' => normalize_float(data['seam_y_mm'], 0.0)
          }
        end

        def normalize_float(value, min_value)
          return nil if value.nil? && min_value.nil?

          number = value.to_f
          return min_value unless number.finite?
          return number.positive? ? number : nil if min_value.nil?

          number < min_value ? min_value : number
        rescue StandardError
          min_value
        end

        def tool_params_for_array_tool
          {
            'mode' => 'windows',
            'brick_bond' => 'stack',
            'brick_layout_rotation_deg' => 0,
            'brick_rotation_deg' => 0,
            'count_x' => @params['count_x'],
            'count_y' => @params['count_y'],
            'auto_step' => @params['auto_step'],
            'step_x_mm' => @params['step_x_mm'],
            'step_y_mm' => @params['step_y_mm'],
            'seam_x_mm' => @params['seam_x_mm'],
            'seam_y_mm' => @params['seam_y_mm'],
            'orientation_mode' => 'plane',
            'place_on_surface' => true,
            'align_to_normal' => true,
            'random_quadrant' => false,
            'drop_to_ground' => false,
            'vertical_up' => false,
            'simplify_preview' => false
          }
        end

        def default_params
          {
            'count_x' => 1,
            'count_y' => 1,
            'axis_spacing_mm' => 3300.0,
            'floor_height_mm' => 3000.0,
            'auto_step' => false,
            'step_x_mm' => 3300.0,
            'step_y_mm' => 3000.0,
            'seam_x_mm' => 0.0,
            'seam_y_mm' => 0.0
          }
        end

        def parse_payload(payload)
          return {} unless payload
          return payload if payload.is_a?(Hash)

          JSON.parse(payload.to_s)
        rescue StandardError
          {}
        end

        def invalidate_view
          Sketchup.active_model&.active_view&.invalidate
        rescue StandardError
          nil
        end

        def session_params_for_storage(params)
          data = params.is_a?(Hash) ? params : {}
          {
            'count_x' => data['count_x'].to_i,
            'count_y' => data['count_y'].to_i,
            'axis_spacing_mm' => data['axis_spacing_mm'].to_f,
            'floor_height_mm' => data['floor_height_mm'].to_f
          }
        end

        def persist_session_params
          return unless @host.respond_to?(:write_win_array_session_params)

          @host.write_win_array_session_params(session_params_for_storage(@params))
        rescue StandardError
          nil
        end

        def array_storage
          @host.send(:ensure_storage_for_refresh!) if @host.respond_to?(:send)
        rescue StandardError
          nil
        end

        def set_library_pick_mode(message)
          @host.set_array_library_pick_mode(true, message.to_s) if @host.respond_to?(:set_array_library_pick_mode)
        rescue StandardError
          nil
        end

        def clear_library_pick_mode
          @host.set_array_library_pick_mode(false, '') if @host.respond_to?(:set_array_library_pick_mode)
        rescue StandardError
          nil
        end

        def report_error(scope, error)
          UI.messagebox("Ошибка (#{scope}):\n#{error.message}")
          Logger.error("WinArray: #{scope}", error) rescue nil
        rescue StandardError
          nil
        end

        def debug_console(event_name, payload = {})
          puts("[CLB][WinArray] #{event_name}: #{payload.inspect}")
        rescue StandardError
          nil
        end

        def vector_hash_for_debug(vector)
          return nil unless vector

          { 'x' => vector.x.to_f, 'y' => vector.y.to_f, 'z' => vector.z.to_f }
        rescue StandardError
          nil
        end

        def point_hash_for_debug(point)
          return nil unless point

          { 'x' => point.x.to_f, 'y' => point.y.to_f, 'z' => point.z.to_f }
        rescue StandardError
          nil
        end

        def transform_hash_for_debug(transform)
          return nil unless transform.is_a?(Geom::Transformation)

          {
            'origin' => point_hash_for_debug(ORIGIN.transform(transform)),
            'x_axis' => vector_hash_for_debug(X_AXIS.transform(transform)),
            'y_axis' => vector_hash_for_debug(Y_AXIS.transform(transform)),
            'z_axis' => vector_hash_for_debug(Z_AXIS.transform(transform))
          }
        rescue StandardError
          nil
        end

        def transform_delta_hash(left, right)
          return nil unless left.is_a?(Geom::Transformation) && right.is_a?(Geom::Transformation)

          left_origin = ORIGIN.transform(left)
          right_origin = ORIGIN.transform(right)
          {
            'dx' => right_origin.x.to_f - left_origin.x.to_f,
            'dy' => right_origin.y.to_f - left_origin.y.to_f,
            'dz' => right_origin.z.to_f - left_origin.z.to_f
          }
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
