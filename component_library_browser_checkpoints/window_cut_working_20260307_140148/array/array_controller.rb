require 'json'

require 'securerandom'

module Drale
  module ComponentLibraryBrowser
    module ArrayLayout
      class ArrayController
        PALETTE_TITLE = 'Раскладка (Окна/Кирпич)'.freeze
        PALETTE_KEY = 'DraleComponentLibraryArrayPalette'.freeze
        MAX_PREVIEW_EDGE_POINTS = 120_000
        MAX_PREVIEW_TRI_POINTS = 180_000
        ARRAY_ATTR_DICTIONARY = 'ComponentLibraryBrowser'.freeze
        ARRAY_ATTR_ID_KEY = 'array_id'.freeze
        WINDOWS_DEBUG = false

        def initialize(host)
          @host = host
          @palette = nil
          @array_tool = nil
          @source_definition = nil
          @source_name = 'Не выбран'
          @source_item_id = nil
          @source_path = nil
          @source_bbox_x = 0.0
          @source_bbox_y = 0.0
          @preview_cache = empty_preview_cache
          @session_active = false
          @closing = false
          @non_cutting_warning_shown = false
          @params = normalize_params(default_params)
          merge_insert_defaults!
          @params = normalize_params(@params)
        end

        def launch
          reset_source!
          ensure_palette!
          show_palette!
          ensure_tool!
          @array_tool.reset_point!
          activate_array_tool!
          @session_active = true
          @non_cutting_warning_shown = false
          @host.set_array_tool_active(true) if @host.respond_to?(:set_array_tool_active)
          push_palette_state
          update_status_prompt
          Logger.debug('ArrayController launch', { 'params' => @params })
          true
        rescue StandardError => error
          report_error('Запуск инструмента "Раскладка"', error)
          false
        end

        def select_source_model
          return false unless ensure_model_available

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
                  activate_array_tool_deferred!
                end
              end,
            on_cancel: proc do
              activate_array_tool_deferred!
              update_status_prompt
            end
          )
          Sketchup.active_model.select_tool(pick_tool)
          Sketchup.status_text = 'Пипетка: выберите компонент или группу в модели. Esc - отмена.'
          true
        rescue StandardError => error
          report_error('Выбор прототипа пипеткой', error)
          false
        end

        def select_source_library
          return false unless @host.respond_to?(:open_library)

          @host.open_library
          set_library_pick_mode('Выберите элемент для раскладки')
          Sketchup.status_text = 'Библиотека: выберите элемент для раскладки.'
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
            UI.messagebox("Файл прототипа не найден:\n#{skp_path}")
            return false
          end

          model = Sketchup.active_model
          definition = Compat.load_definition_from_file(
            skp_path,
            definitions: model.definitions,
            notify_user: true,
            context: 'array_pick_library',
            library_path: storage.lib_root
          )
          if @host.respond_to?(:send)
            definition = @host.send(:ensure_component_definition_for_insert, definition)
          end
          set_source_definition(
            definition,
            display_name: item['name'].to_s.strip.empty? ? FS.display_name_from_skp(skp_path) : item['name'].to_s,
            source: 'library',
            item_id: item['id'],
            source_path: skp_path
          )
          clear_library_pick_mode
          activate_array_tool_deferred!
          true
        rescue StandardError => error
          report_error('Выбор прототипа из библиотеки', error)
          false
        end

        def update_params(payload = nil)
          data = parse_payload(payload)
          previous_auto = !!@params['auto_step']
          @params = normalize_params(@params.merge(data))
          @array_tool&.update_params(tool_params_for_array_tool)
          if previous_auto && !@params['auto_step']
            sync_steps_from_current_auto!
            @array_tool&.update_params(tool_params_for_array_tool)
          end
          push_palette_state
          invalidate_view
          update_status_prompt
          activate_array_tool_deferred! if source_ready?
          Logger.debug('ArrayController update_params', { 'params' => @params, 'tool_params' => tool_params_for_array_tool })
          true
        rescue StandardError => error
          report_error('Обновление параметров раскладки', error)
          false
        end

        def apply
          unless source_ready?
            UI.messagebox('Сначала выберите прототип для раскладки.')
            return false
          end

          ensure_tool!
          # Capture target before reading apply data. Re-selecting the tool from the
          # palette callback can move focus back to the dialog and invalidate hover.
          @array_tool&.capture_current_target!

          model = Sketchup.active_model
          unless model
            UI.messagebox('Модель SketchUp недоступна.')
            return false
          end

          operation_started = false
          mode = @params['mode'].to_s
          array_id = next_array_id
          created_count = 0
          target = nil

          if mode == 'windows'
            target = @array_tool&.surface_target_for_apply
            if (!target || !target[:face] || !target[:face].valid?) && @array_tool&.respond_to?(:surface_target_from_preview_state)
              target = @array_tool.surface_target_from_preview_state
            end
            Logger.debug(
              'ArrayController apply windows target',
              {
                'params' => @params,
                'tool_snapshot' => @array_tool&.debug_snapshot,
                'target_valid' => !!(target && target[:face] && target[:face].valid?)
              }
            )
            unless target && target[:face] && target[:face].valid?
              activate_array_tool_deferred!
              UI.messagebox('Наведите курсор на грань стены (чтобы был предпросмотр), затем нажмите ✅.')
              return false
            end

            transforms = @array_tool.transforms_for_apply
            Logger.debug('ArrayController apply windows transforms', { 'count' => transforms.length, 'tool_snapshot' => @array_tool&.debug_snapshot })
            if transforms.empty?
              UI.messagebox('Нет данных для построения раскладки.')
              return false
            end

            model.start_operation('Раскладка компонентов', true)
            operation_started = true
            created_count = apply_windows_instances(model, transforms, target, array_id)
            model.selection.clear
            @host.set_last_windows_array_id(array_id) if @host.respond_to?(:set_last_windows_array_id)
          else
            transforms = @array_tool.transforms_for_apply
            if transforms.empty?
              UI.messagebox('Нет данных для построения раскладки.')
              return false
            end

            target = @array_tool&.surface_target_for_apply
            model.start_operation('Раскладка компонентов', true)
            operation_started = true
            created_count = apply_group_instances(model, transforms, array_id)
          end

          Logger.info(
            'Раскладка применена',
            {
              'mode' => mode,
              'array_id' => array_id,
              'instances' => created_count
            }
          )
          model.commit_operation
          operation_started = false

          close_session!
          true
        rescue StandardError => error
          model = Sketchup.active_model
          model.abort_operation if model && operation_started
          report_error('Применение раскладки', error)
          false
        end

        def cancel
          close_session!
          true
        rescue StandardError => error
          report_error('Отмена раскладки', error)
          false
        end

        def reset_point
          ensure_tool!
          @array_tool.reset_point!
          invalidate_view
          true
        rescue StandardError => error
          report_error('Сброс точки раскладки', error)
          false
        end

        def update_status_prompt
          if source_ready?
            if @params['mode'].to_s == 'windows'
              Sketchup.status_text = 'Наведите курсор на грань для предпросмотра. Нажмите ✅ или Enter для применения. Esc - отмена.'
            else
              Sketchup.status_text = 'Клик - закрепить точку. Перемещайте мышь для предпросмотра. Enter=Применить, Esc=Отмена.'
            end
          else
            Sketchup.status_text = 'Раскладка: выберите прототип (пипетка/библиотека). Enter=Применить, Esc=Отмена.'
          end
        rescue StandardError
          # ignore status errors
        end

        def source_ready?
          @source_definition && @source_definition.valid?
        end

        def session_active?
          !!@session_active
        end

        def reset_source!
          @source_definition = nil
          @source_name = 'Не выбран'
          @source_item_id = nil
          @source_path = nil
          @source_bbox_x = 0.0
          @source_bbox_y = 0.0
          @preview_cache = empty_preview_cache
          @array_tool&.set_source(nil, cache: @preview_cache, bbox_x: 0.0, bbox_y: 0.0)
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

        private

        def ensure_model_available
          model = Sketchup.active_model
          raise 'Модель SketchUp недоступна.' unless model

          true
        end

        def ensure_tool!
          return @array_tool if @array_tool

          @array_tool = Tools::ArrayTool.new(self)
          @array_tool.update_params(tool_params_for_array_tool)
          @array_tool.set_source(@source_definition, cache: @preview_cache, bbox_x: @source_bbox_x, bbox_y: @source_bbox_y) if source_ready?
          @array_tool
        end

        def activate_array_tool!
          model = Sketchup.active_model
          return false unless model

          ensure_tool!
          model.select_tool(@array_tool)
          true
        rescue StandardError
          false
        end

        def activate_array_tool_deferred!
          activated_now = activate_array_tool!
          UI.start_timer(0, false) do
            activate_array_tool!
            update_status_prompt
          end
          activated_now
        rescue StandardError
          false
        end

        def default_params
          {
            'mode' => 'brick',
            'brick_bond' => 'stack',
            'brick_layout_rotation_deg' => 0,
            'brick_rotation_deg' => 0,
            'count_x' => 4,
            'count_y' => 3,
            'auto_step' => true,
            'step_x_mm' => 1500.0,
            'step_y_mm' => 3300.0,
            'seam_x_mm' => 0.0,
            'seam_y_mm' => 0.0,
            'orientation_mode' => 'auto',
            'place_on_surface' => true,
            'align_to_normal' => false,
            'random_quadrant' => false,
            'drop_to_ground' => false,
            'vertical_up' => false,
            'simplify_preview' => false
          }
        end

        def merge_insert_defaults!
          return unless @host.respond_to?(:send)

          insert_defaults = @host.send(:read_insert_options)
          return unless insert_defaults.is_a?(Hash)

          @params['place_on_surface'] = !!insert_defaults['place_on_surface']
          @params['align_to_normal'] = !!insert_defaults['align_to_normal']
          @params['random_quadrant'] = !!insert_defaults['random_quadrant']
          @params['drop_to_ground'] = !!insert_defaults['drop_to_ground']
        rescue StandardError
          # ignore fallback defaults
        end

        def normalize_params(raw)
          data = raw.is_a?(Hash) ? raw : {}
          mode = data['mode'].to_s
          mode = %w[windows brick].include?(mode) ? mode : 'windows'
          bond = data['brick_bond'].to_s
          bond = %w[stack half third].include?(bond) ? bond : 'stack'
          layout_rotation = normalize_quadrant_rotation(data['brick_layout_rotation_deg'])
          brick_rotation = normalize_brick_rotation(data['brick_rotation_deg'])
          orientation = data['orientation_mode'].to_s
          orientation = %w[auto plane world].include?(orientation) ? orientation : 'auto'

          params = {
            'mode' => mode,
            'brick_bond' => bond,
            'brick_layout_rotation_deg' => layout_rotation,
            'brick_rotation_deg' => brick_rotation,
            'count_x' => normalize_int(data['count_x'], 1, 500),
            'count_y' => normalize_int(data['count_y'], 1, 500),
            'auto_step' => !!data['auto_step'],
            'step_x_mm' => normalize_float(data['step_x_mm'], 1.0, 100_000.0),
            'step_y_mm' => normalize_float(data['step_y_mm'], 1.0, 100_000.0),
            'seam_x_mm' => normalize_float(data['seam_x_mm'], 0.0, 50_000.0),
            'seam_y_mm' => normalize_float(data['seam_y_mm'], 0.0, 50_000.0),
            'orientation_mode' => orientation,
            'place_on_surface' => !!data['place_on_surface'],
            'align_to_normal' => !!data['align_to_normal'],
            'random_quadrant' => !!data['random_quadrant'],
            'drop_to_ground' => !!data['drop_to_ground'],
            'vertical_up' => !!data['vertical_up'],
            'simplify_preview' => !!data['simplify_preview']
          }
          if mode == 'windows'
            params['place_on_surface'] = true
            params['orientation_mode'] = 'plane'
            params['align_to_normal'] = false
            params['random_quadrant'] = false
            params['drop_to_ground'] = false
            params['vertical_up'] = false
            params['brick_bond'] = 'stack'
            params['brick_layout_rotation_deg'] = 0
            params['brick_rotation_deg'] = 0
          end
          params['drop_to_ground'] = false unless params['orientation_mode'] == 'world' && !params['vertical_up']
          params
        end

        def tool_params_for_array_tool
          params = @params.dup
          return params unless params['mode'].to_s == 'windows'

          params.merge(
            'mode' => 'brick',
            'brick_bond' => 'stack',
            'brick_layout_rotation_deg' => 0,
            'brick_rotation_deg' => 0,
            'orientation_mode' => 'plane',
            'place_on_surface' => true,
            'align_to_normal' => true,
            'random_quadrant' => false,
            'drop_to_ground' => false,
            'vertical_up' => false
          )
        rescue StandardError
          @params
        end

        def normalize_brick_rotation(value)
          normalize_quadrant_rotation(value)
        end

        def normalize_quadrant_rotation(value)
          deg = value.to_i
          allowed = [0, 90, 180, 270]
          allowed.include?(deg) ? deg : 0
        rescue StandardError
          0
        end

        def normalize_int(value, min_value, max_value)
          number = value.to_i
          number = min_value if number < min_value
          number = max_value if number > max_value
          number
        rescue StandardError
          min_value
        end

        def normalize_float(value, min_value, max_value)
          number = value.to_f
          number = min_value if number < min_value
          number = max_value if number > max_value
          number
        rescue StandardError
          min_value
        end

        def parse_payload(payload)
          case payload
          when nil
            {}
          when String
            stripped = payload.strip
            return {} if stripped.empty?

            JSON.parse(stripped)
          when Hash
            payload
          else
            {}
          end
        rescue JSON::ParserError
          {}
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

        def ensure_palette!
          return if @palette

          options = {
            dialog_title: PALETTE_TITLE,
            preferences_key: PALETTE_KEY,
            style: UI::HtmlDialog::STYLE_UTILITY,
            resizable: true,
            width: 1180,
            height: 96,
            min_width: 920,
            min_height: 82
          }
          @palette = UI::HtmlDialog.new(options)
          @palette.set_file(File.join(__dir__, '..', 'ui', 'array_palette.html'))
          @palette.set_on_closed do
            was_closing = @closing
            @palette = nil
            unless was_closing
              @session_active = false
              @host.set_array_tool_active(false) if @host.respond_to?(:set_array_tool_active)
              clear_library_pick_mode
              model = Sketchup.active_model
              model.select_tool(nil) if model
              Sketchup.status_text = ''
            end
          end
          register_palette_callbacks
        end

        def show_palette!
          return unless @palette

          @palette.show
          if @palette.respond_to?(:set_position)
            @palette.set_position(24, 40)
          end
        end

        def register_palette_callbacks
          return unless @palette

          @palette.add_action_callback('array_palette_ready') do |_ctx, _payload|
            push_palette_state
            activate_array_tool_deferred! if @session_active && source_ready?
          end

          @palette.add_action_callback('array_select_source_model') do |_ctx, _payload|
            select_source_model
          end

          @palette.add_action_callback('array_select_source_library') do |_ctx, _payload|
            select_source_library
          end

          @palette.add_action_callback('array_params_update') do |_ctx, payload|
            update_params(payload)
          end

          @palette.add_action_callback('array_apply') do |_ctx, _payload|
            apply
          end

          @palette.add_action_callback('array_cancel') do |_ctx, _payload|
            cancel
          end

          @palette.add_action_callback('array_reset_point') do |_ctx, _payload|
            reset_point
          end
        end

        def push_palette_state
          return unless @palette

          state = palette_state_hash
          script = "window.ArrayPalette && window.ArrayPalette.setState(#{JSON.generate(state)});"
          @palette.execute_script(script)
        rescue StandardError
          # ignore palette sync failures
        end

        def close_session!
          return if @closing

          @closing = true
          clear_library_pick_mode
          @session_active = false
          @host.set_array_tool_active(false) if @host.respond_to?(:set_array_tool_active)
          close_palette
          model = Sketchup.active_model
          model.select_tool(nil) if model
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
          raise ArgumentError, 'Определение прототипа невалидно.' unless definition && definition.valid?

          @source_definition = definition
          @source_name = display_name.to_s.strip
          @source_name = source.to_s == 'library' ? 'Элемент библиотеки' : 'Компонент в модели' if @source_name.empty?
          @source_item_id = item_id
          @source_path = source_path
          sx, sy, sz = source_scale_factors(source_entity, source_transform)
          plane_x, plane_y, thickness = source_plane_dimensions(definition, sx, sy, sz)
          @source_bbox_x = plane_x.to_f
          @source_bbox_y = plane_y.to_f
          # On source pick, sync numeric step fields to auto-step values
          # so user sees practical defaults and can edit manually if needed.
          @params['step_x_mm'] = auto_step_mm_for(plane_x)
          @params['step_y_mm'] = auto_step_mm_for(plane_y)
          if opening_component?(definition)
            @params['place_on_surface'] = true
          end
          @params = normalize_params(@params)
          @preview_cache = build_preview_cache(definition)
          ensure_tool!
          @array_tool.set_source(
            definition,
            cache: @preview_cache,
            bbox_x: @source_bbox_x,
            bbox_y: @source_bbox_y,
            bbox_z: thickness.to_f,
            scale_x: sx,
            scale_y: sy,
            scale_z: sz
          )
          sync_steps_from_current_auto!
          @array_tool.update_params(tool_params_for_array_tool)
          @array_tool.reset_point!
          activate_array_tool! if @session_active
          push_palette_state
          update_status_prompt
          invalidate_view
          Logger.debug(
            'ArrayController set_source_definition',
            {
              'source' => source.to_s,
              'display_name' => @source_name,
              'definition_name' => definition.respond_to?(:name) ? definition.name.to_s : '',
              'bbox_x' => @source_bbox_x,
              'bbox_y' => @source_bbox_y,
              'params' => @params,
              'tool_params' => tool_params_for_array_tool
            }
          )
          true
        end

        def auto_step_mm_for(size_length)
          base_mm = size_length.respond_to?(:to_mm) ? size_length.to_mm.to_f : size_length.to_f
          base_mm.round(2)
        rescue StandardError
          0.0
        end

        def source_scale_factors(entity, world_transform = nil)
          tr =
            if world_transform.is_a?(Geom::Transformation)
              world_transform
            elsif entity && entity.respond_to?(:transformation)
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

        def source_plane_dimensions(definition, sx, sy, sz)
          bounds = definition.bounds
          dims = [
            [bounds.width * sx, :x],
            [bounds.height * sz, :z],
            [bounds.depth * sy, :y]
          ].sort_by { |entry| entry[0].to_f.abs }

          thickness = dims[0][0]
          plane_dims = dims[1, 2].map(&:first).sort.reverse
          plane_x = plane_dims[0] || bounds.width * sx
          plane_y = plane_dims[1] || bounds.height * sz
          [plane_x, plane_y, thickness]
        rescue StandardError
          [definition.bounds.width * sx, definition.bounds.height * sz, definition.bounds.depth * sy]
        end

        def sync_steps_from_current_auto!
          return unless @array_tool

          suggestion = @array_tool.suggested_auto_step_mm
          return unless suggestion.is_a?(Hash)

          sx = normalize_float(suggestion['step_x_mm'], 1.0, 100_000.0)
          sy = normalize_float(suggestion['step_y_mm'], 1.0, 100_000.0)
          @params['step_x_mm'] = sx
          @params['step_y_mm'] = sy
        rescue StandardError
          # keep current step fields on any sync failure
        end

        def build_preview_cache(definition)
          edges = []
          triangles = []
          truncated = false
          collect_preview_geometry(
            definition.entities,
            Geom::Transformation.new,
            edges,
            triangles,
            depth: 0
          )
          if edges.length > MAX_PREVIEW_EDGE_POINTS || triangles.length > MAX_PREVIEW_TRI_POINTS
            truncated = true
            # Avoid broken partial geometry for very heavy source objects.
            edges = bbox_edge_points(definition.bounds)
            triangles = []
          end
          {
            'edges' => edges,
            'triangles' => triangles,
            'edge_segments' => edges.length / 2,
            'triangle_count' => triangles.length / 3,
            'truncated' => truncated
          }
        rescue StandardError => error
          Logger.warn('Не удалось собрать кеш предпросмотра', { 'message' => error.message.to_s })
          empty_preview_cache
        end

        def bbox_edge_points(bounds)
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

        def collect_preview_geometry(entities, transform, edge_points, triangle_points, depth:)
          return if depth > 12
          return if edge_points.length > MAX_PREVIEW_EDGE_POINTS
          return if triangle_points.length > MAX_PREVIEW_TRI_POINTS

          entities.each do |entity|
            case entity
            when Sketchup::Edge
              edge_points << entity.start.position.transform(transform)
              edge_points << entity.end.position.transform(transform)
            when Sketchup::Face
              append_face_triangles(entity, transform, triangle_points)
            when Sketchup::ComponentInstance, Sketchup::Group
              child_tr = transform * entity.transformation
              collect_preview_geometry(entity.definition.entities, child_tr, edge_points, triangle_points, depth: depth + 1)
            end
            break if edge_points.length > MAX_PREVIEW_EDGE_POINTS || triangle_points.length > MAX_PREVIEW_TRI_POINTS
          end
        rescue StandardError
          # ignore malformed geometry
        end

        def append_face_triangles(face, transform, triangle_points)
          mesh = face.mesh
          points = mesh.points
          mesh.polygons.each do |polygon|
            ids = polygon.map { |index| index.to_i.abs }.reject(&:zero?)
            next if ids.length < 3

            p0 = points[ids[0] - 1].transform(transform)
            1.upto(ids.length - 2) do |idx|
              p1 = points[ids[idx] - 1].transform(transform)
              p2 = points[ids[idx + 1] - 1].transform(transform)
              triangle_points << p0
              triangle_points << p1
              triangle_points << p2
            end
          end
        rescue StandardError
          # ignore broken meshes
        end

        def invalidate_view
          model = Sketchup.active_model
          return unless model

          model.active_view.invalidate
        rescue StandardError
          # ignore invalidate failures
        end

        def array_storage
          if @host.respond_to?(:send)
            @host.send(:ensure_storage_for_refresh!)
          else
            nil
          end
        rescue StandardError
          nil
        end

        def set_library_pick_mode(message)
          return unless @host.respond_to?(:set_array_library_pick_mode)

          @host.set_array_library_pick_mode(true, message.to_s)
        end

        def clear_library_pick_mode
          return unless @host.respond_to?(:set_array_library_pick_mode)

          @host.set_array_library_pick_mode(false, '')
        end

        def drop_to_ground_allowed?
          @params['drop_to_ground'] && @params['orientation_mode'].to_s == 'world'
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

        def next_array_id
          "#{Time.now.to_i}-#{SecureRandom.hex(4)}"
        rescue StandardError
          Time.now.to_i.to_s
        end

        def tag_array_entity(entity, array_id)
          return unless entity && entity.valid?

          entity.set_attribute(ARRAY_ATTR_DICTIONARY, ARRAY_ATTR_ID_KEY, array_id.to_s)
        rescue StandardError
          # ignore attribute errors
        end

        def apply_windows_instances(model, transforms, target, array_id)
          face = target ? target[:face] : nil
          entities = target ? target[:entities] : nil
          basis = target ? target[:transform] : nil
          face_pid = target ? target[:face_pid].to_i : 0
          opening = opening_component?(@source_definition)
          unless face && face.valid? && entities.is_a?(Sketchup::Entities) && basis.is_a?(Geom::Transformation)
            raise 'Не удалось получить валидную цель вставки окон (face/entities/transform).'
          end

          unless opening
            warn_non_cutting_window_once
          end

          inserted = 0
          glue_results = []
          transforms.each_with_index do |tr, index|
            # Re-fetch the face by persistent_id in case the entity was modified
            # (e.g. internally rebuilt by SketchUp) after a previous gluing operation.
            current_face = face && face.valid? ? face : resolve_face_by_pid(entities, face_pid)
            instance = add_instance_in_entities(entities, basis, tr)
            tag_array_entity(instance, array_id)

            glued = glue_instance_to_face(instance, current_face)
            if opening && !glued
              instance.erase! if instance.valid?
              flipped_tr = flip_opening_world_transform(tr)
              instance = add_instance_in_entities(entities, basis, flipped_tr)
              tag_array_entity(instance, array_id)
              glued = glue_instance_to_face(instance, current_face)
            end

            if opening && !glued
              instance.erase! if instance&.valid?
              raise 'Не удалось приклеить прорезной компонент к выбранной грани.'
            end

            face = current_face if current_face && current_face.valid?

            glue_results << { 'index' => index, 'glued' => !!glued }
            inserted += 1
          end

          log_windows_apply_debug('after_apply', target, @array_tool&.windows_apply_diagnostics, transforms.length, glue_results, { 'preview_transforms' => true })
          inserted
        end

        def apply_group_instances(model, transforms, array_id)
          edit = model.edit_transform
          group = model.active_entities.add_group
          group.name = "Раскладка: #{@source_name}"
          tag_array_entity(group, array_id)
          entities = group.entities
          transforms.each do |tr|
            local_tr = edit.inverse * tr
            instance = entities.add_instance(@source_definition, local_tr)
            tag_array_entity(instance, array_id)
            apply_ground_snap(instance, model) if drop_to_ground_allowed?
          end
          force_group_unglued(group)
          transforms.length
        end

        def warn_non_cutting_window_once
          return if @non_cutting_warning_shown

          @non_cutting_warning_shown = true
          UI.messagebox('Выбранный компонент не имеет режима «Прорезать отверстие». Вставка выполнена без прорезания.')
        rescue StandardError
          # ignore warning failures
        end

        def log_windows_apply_debug(stage, target, diagnostics, transform_count, glue_results = nil, extra = nil)
          return unless WINDOWS_DEBUG

          payload = {
            'stage' => stage.to_s,
            'hover_valid' => diagnostics.is_a?(Hash) ? diagnostics[:hover_valid] : nil,
            'hover_face_valid' => diagnostics.is_a?(Hash) ? diagnostics[:hover_face_valid] : nil,
            'cached_target' => diagnostics.is_a?(Hash) ? diagnostics[:cached_target] : nil,
            'cached_face_valid' => diagnostics.is_a?(Hash) ? diagnostics[:cached_face_valid] : nil,
            'face_pid' => diagnostics.is_a?(Hash) ? diagnostics[:face_pid] : nil,
            'axis_lengths' => diagnostics.is_a?(Hash) ? diagnostics[:axis_lengths] : nil,
            'axis_dots' => diagnostics.is_a?(Hash) ? diagnostics[:axis_dots] : nil,
            'face_valid' => !!(target && target[:face] && target[:face].valid?),
            'target_source' => target ? target[:source].to_s : '',
            'entities_class' => target && target[:entities] ? target[:entities].class.to_s : '',
            'transform_valid' => !!(target && target[:transform].is_a?(Geom::Transformation)),
            'transform_count' => transform_count.to_i
          }
          payload['glue_results'] = glue_results if glue_results
          payload.merge!(extra) if extra.is_a?(Hash)

          Logger.info('WINDOWS_DEBUG apply', payload)
          puts("[WINDOWS_DEBUG] #{payload}")
        rescue StandardError => error
          Logger.warn('WINDOWS_DEBUG logging failed', { 'message' => error.message.to_s })
        end

        def opening_component?(definition)
          return false unless definition && definition.valid?
          return false unless definition.respond_to?(:behavior)

          behavior = definition.behavior
          return false unless behavior && behavior.respond_to?(:cuts_opening?)

          !!behavior.cuts_opening?
        rescue StandardError
          false
        end

        def glue_instance_to_face(instance, face)
          return false unless instance && instance.valid?
          return false unless face && face.valid?
          return false unless instance.respond_to?(:glued_to=)

          instance.glued_to = face
          true
        rescue StandardError
          false
        end

        def add_instance_in_entities(entities, basis, world_tr)
          local_tr = basis.inverse * world_tr
          entities.add_instance(@source_definition, local_tr)
        end

        def flip_opening_world_transform(world_tr)
          origin = ORIGIN.transform(world_tr)
          x_axis = X_AXIS.transform(world_tr)
          y_axis = Y_AXIS.transform(world_tr)
          z_axis = Z_AXIS.transform(world_tr)
          Geom::Transformation.axes(origin, x_axis.reverse, y_axis, z_axis.reverse)
        rescue StandardError
          world_tr
        end

        # Finds a face in entities by persistent_id.
        # Used to re-fetch the glue target if the entity reference becomes stale
        # after a previous gluing operation internally modifies the face.
        def resolve_face_by_pid(entities, pid)
          return nil unless pid.to_i.positive? && entities.is_a?(Sketchup::Entities)

          entities.grep(Sketchup::Face).find do |f|
            f.valid? && f.respond_to?(:persistent_id) && f.persistent_id.to_i == pid
          end
        rescue StandardError
          nil
        end

        def force_group_unglued(group)
          return unless group && group.valid?

          if group.respond_to?(:glued_to=)
            group.glued_to = nil
          end

          return unless group.respond_to?(:definition)

          definition = group.definition
          return unless definition && definition.respond_to?(:behavior)

          behavior = definition.behavior
          return unless behavior

          if behavior.respond_to?(:is2d?) && behavior.respond_to?(:is2d=) && behavior.is2d?
            behavior.is2d = false
          end
          if behavior.respond_to?(:cuts_opening?) && behavior.respond_to?(:cuts_opening=) && behavior.cuts_opening?
            behavior.cuts_opening = false
          end
        rescue StandardError
          # keep group creation robust even if behavior flags are unavailable
        end

        def report_error(scope, error)
          UI.messagebox("Ошибка (#{scope}):\n#{error.message}")
          Logger.error("Ошибка: #{scope}", error, Compat.environment_snapshot(library_path: library_path_for_log))
        rescue StandardError
          # keep controller stable on reporting errors
        end

        def library_path_for_log
          storage = array_storage
          return '' unless storage

          storage.lib_root.to_s
        rescue StandardError
          ''
        end
      end
    end
  end
end
