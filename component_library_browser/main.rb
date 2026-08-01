require 'json'
require 'fileutils'
require 'securerandom'
require 'time'
require 'cgi'
require 'digest/sha1'
require 'tmpdir'

require_relative 'fs'
require_relative 'storage'
require_relative 'logger'
require_relative 'compat'
require_relative 'tools/layout_geometry'
require_relative 'tools/array_tool'
require_relative 'tools/brick_layout_tool'
require_relative 'tools/window_layout_tool'
require_relative 'array/array_controller'
require_relative 'array/win_array_controller'
require_relative 'services/model_definitions'
require_relative 'services/replacer'
require_relative 'services/metadata'
require_relative 'services/preview_regenerator'
require_relative 'services/pack_transfer'
require_relative 'tools/pick_source_tool'
require_relative 'services/updater'
require_relative 'services/runtime_manifest'

module Drale
  module ComponentLibraryBrowser
    extend self

    PREFS_NAMESPACE = 'ComponentLibraryBrowser'.freeze
    PREFS_LIB_ROOT_KEY = 'lib_root'.freeze
    PREFS_PINNED_CATEGORIES_KEY = 'pinned_categories'.freeze
    PREFS_INSERT_OPTIONS_KEY = 'insert_options'.freeze
    PREFS_HEAVY_THRESHOLD_KEY = 'heavy_faces_threshold'.freeze
    RECENT_LIMIT = 50
    MAX_PINNED_CATEGORIES = 10
    ARRAY_ATTR_DICTIONARY = 'ComponentLibraryBrowser'.freeze
    ARRAY_ATTR_ID_KEY = 'array_id'.freeze

    MENU_ROOT = "\u0411\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0430 \u043a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442\u043e\u0432".freeze
    TOOLBAR_NAME = "\u0411\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0430 \u043a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442\u043e\u0432".freeze
    CONTEXT_MENU_TEXT = "\u0414\u043e\u0431\u0430\u0432\u0438\u0442\u044c \u0432 \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0443...".freeze
    ADD_CATEGORY_OPTION = "\u002b \u041a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u044f...".freeze

    DIALOG_OPTIONS = {
      dialog_title: "\u0411\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0430 \u043a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442\u043e\u0432",
      preferences_key: 'DraleComponentLibraryBrowserDialog',
      style: UI::HtmlDialog::STYLE_DIALOG,
      resizable: true,
      width: 1220,
      height: 760,
      min_width: 760,
      min_height: 560
    }.freeze

    class NativeBrushEntitiesObserver < Sketchup::EntitiesObserver
      def initialize(owner)
        @owner = owner
      end

      def onElementAdded(_entities, entity)
        @owner.handle_native_brush_element_added(entity)
      rescue StandardError
        # Ignore observer errors
      end
    end

    class DialogSelectionObserver < Sketchup::SelectionObserver
      def initialize(owner)
        @owner = owner
      end

      def onSelectionAdded(_selection, _entity)
        @owner.handle_dialog_selection_changed
      rescue StandardError
        # Ignore observer errors
      end

      def onSelectionRemoved(_selection, _entity)
        @owner.handle_dialog_selection_changed
      rescue StandardError
        # Ignore observer errors
      end

      def onSelectionBulkChange(_selection)
        @owner.handle_dialog_selection_changed
      rescue StandardError
        # Ignore observer errors
      end

      def onSelectionCleared(_selection)
        @owner.handle_dialog_selection_changed
      rescue StandardError
        # Ignore observer errors
      end
    end

    def boot!
      pending_update = Updater.apply_pending_update
      if pending_update && pending_update['restart_required']
        Logger.warn('Pending update remains staged; restart SketchUp again after closing locked files.')
      elsif pending_update && pending_update['success']
        Sketchup.status_text = "Update v#{pending_update['version']} installed. Restart SketchUp to load the new code."
        Logger.info("Pending update v#{pending_update['version']} installed; restart SketchUp before using the new code.")
      end
      setup_commands
      setup_menu
      setup_toolbar
      setup_context_menu
      Logger.info('Плагин загружен')
      schedule_background_update_check
    end

    def open_library
      return unless ensure_storage!

      show_dialog
      push_state_to_dialog
    rescue StandardError => error
      show_error("\u041e\u0442\u043a\u0440\u044b\u0442\u0438\u0435 \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0438", error)
    end

    def save_selected_to_library(payload = nil)
      return unless ensure_storage!

      model = Sketchup.active_model
      selection = model.selection
      unless selection.count == 1
        UI.messagebox("\u0412\u044b\u0431\u0435\u0440\u0438\u0442\u0435 \u0440\u043e\u0432\u043d\u043e \u043e\u0434\u0438\u043d \u043e\u0431\u044a\u0435\u043a\u0442 (\u0413\u0440\u0443\u043f\u043f\u0430 \u0438\u043b\u0438 \u041a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442).")
        return
      end

      entity = selection.first
      unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
        UI.messagebox("\u041f\u043e\u0434\u0434\u0435\u0440\u0436\u0438\u0432\u0430\u044e\u0442\u0441\u044f \u0442\u043e\u043b\u044c\u043a\u043e \u0413\u0440\u0443\u043f\u043f\u044b \u0438 \u041a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442\u044b.")
        return
      end

      defaults = parse_payload(payload)
      categories = @storage.index['categories']
      default_category = defaults['category'].to_s.strip.empty? ? (categories.first || "\u041e\u0431\u0449\u0430\u044f") : defaults['category'].to_s
      default_name = defaults['name'].to_s.strip
      default_name = entity.definition.name.to_s.strip if default_name.empty?
      default_name = entity.is_a?(Sketchup::Group) ? "\u0413\u0440\u0443\u043f\u043f\u0430" : "\u041a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442" if default_name.to_s.strip.empty?
      default_tags = defaults['tags'].to_s

      result = prompt_save_selected_data(
        default_category: default_category,
        default_name: default_name,
        default_tags: default_tags
      )
      return unless result

      category, name, description, tags_input = result
      saved =
        if entity.is_a?(Sketchup::Group)
          save_group_as_component_to_library(entity, category: category, name: name, description: description, tags: tags_input)
        else
          dedupe = resolve_dedup_for_definition(entity.definition, fallback_name: name)
          return nil unless dedupe
          @storage.save_definition!(
            entity.definition,
            source: 'component',
            category: category,
            display_name: name,
            tags: tags_input,
            description: description,
            content_hash: dedupe['content_hash']
          )
        end
      return nil unless saved

      ensure_item_thumbnail(saved['item'])
      mark_in_model_items_dirty!

      if saved['name_changed']
        UI.messagebox("\u0418\u043c\u044f \u0443\u0436\u0435 \u0435\u0441\u0442\u044c \u0432 \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438.\n\u0421\u043e\u0445\u0440\u0430\u043d\u0435\u043d\u043e \u043a\u0430\u043a: #{saved['final_name']}")
      end

      push_state_to_dialog
      saved
    rescue StandardError => error
      show_error("\u0421\u043e\u0445\u0440\u0430\u043d\u0435\u043d\u0438\u0435 \u0432\u044b\u0434\u0435\u043b\u0435\u043d\u043d\u043e\u0433\u043e", error)
      nil
    end

    def open_settings
      open_library
      @dialog&.execute_script('window.ComponentLibrary && window.ComponentLibrary.openSettings();')
      true
    rescue StandardError => error
      show_error("Настройки", error)
      false
    end

    def change_library_root
      current_root = @storage ? @storage.lib_root : read_saved_root
      selected_root = choose_library_root(current_root)
      return unless selected_root

      configure_storage_root(selected_root, prompt_scan: true)
      push_state_to_dialog
    rescue StandardError => error
      show_error("\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438", error)
    end

    def create_new_library_root
      current_root = @storage ? @storage.lib_root : read_saved_root
      selected_root = choose_library_root(current_root)
      return unless selected_root

      selected_root = File.expand_path(selected_root)
      raise ArgumentError, 'Выберите новую пустую папку библиотеки.' if same_path_ci?(selected_root, current_root)
      raise ArgumentError, 'Новая папка библиотеки должна быть пустой.' if File.directory?(selected_root) && !Dir.children(selected_root).empty?

      configure_storage_root(selected_root, prompt_scan: false)
      push_state_to_dialog
    rescue StandardError => error
      show_error('Создание новой библиотеки', error)
      nil
    end

    def open_log_file
      path = Logger.file_path
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '', mode: 'a:UTF-8') unless File.file?(path)
      system('cmd', '/c', 'start', '', path)
      true
    rescue StandardError => error
      show_error("\u041e\u0442\u043a\u0440\u044b\u0442\u0438\u0435 \u043b\u043e\u0433\u0430", error)
      false
    end

    def refresh_index_only
      storage = ensure_storage_for_refresh!
      return false unless storage

      push_status_to_dialog('Обновление списка...')
      storage.reload_index!
      push_state_to_dialog
      push_status_to_dialog("Обновлено: #{Time.now.strftime('%H:%M')}")
      true
    rescue StandardError => error
      show_error('Обновление списка', error)
      false
    end

    def scan_library_folder
      perform_library_scan(show_summary_message: false)
    end

    def scan_library
      perform_library_scan(show_summary_message: true)
    end

    def insert_item(item_id)
      if array_layout_active?
        UI.messagebox('Инструмент "Раскладка" активен. Завершите его (Enter/Esc), затем используйте обычную вставку.')
        return false
      end
      return unless ensure_storage!

      item = @storage.item_by_id(item_id)
      raise ArgumentError, "\u042d\u043b\u0435\u043c\u0435\u043d\u0442 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d." unless item

      skp_path = FS.to_full_path(@storage.lib_root, item['skp_rel_path'])
      raise "File does not exist: #{skp_path}" unless File.file?(skp_path)

      model = Sketchup.active_model
      definition = Compat.load_definition_from_file(
        skp_path,
        definitions: model.definitions,
        notify_user: true,
        context: 'insert_item',
        library_path: @storage.lib_root
      )
      definition = ensure_component_definition_for_insert(definition)
      mark_in_model_items_dirty!
      start_native_brush_loop(definition, item_id: item['id'], continuous: false)
      arm_native_brush_wait_for_insert
      model.place_component(definition)
      @native_brush_loop[:last_place_at] = Time.now.to_f if @native_brush_loop
      true
    rescue StandardError => error
      show_error("\u0412\u0441\u0442\u0430\u0432\u043a\u0430 \u044d\u043b\u0435\u043c\u0435\u043d\u0442\u0430", error)
      false
    end
    def start_brush_item(item_id)
      if array_layout_active?
        UI.messagebox('Инструмент "Раскладка" активен. Завершите его (Enter/Esc), затем запускайте кисть.')
        return false
      end
      return unless ensure_storage!

      item = @storage.item_by_id(item_id)
      raise ArgumentError, "\u042d\u043b\u0435\u043c\u0435\u043d\u0442 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d." unless item

      skp_path = FS.to_full_path(@storage.lib_root, item['skp_rel_path'])
      raise ArgumentError, "\u0424\u0430\u0439\u043b \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d: #{skp_path}" unless File.file?(skp_path)

      model = Sketchup.active_model
      definition = Compat.load_definition_from_file(
        skp_path,
        definitions: model.definitions,
        notify_user: true,
        context: 'start_brush_item',
        library_path: @storage.lib_root
      )
      definition = ensure_component_definition_for_insert(definition)

      mark_in_model_items_dirty!
      start_native_brush_loop(definition, item_id: item['id'], continuous: true)
      arm_native_brush_wait_for_insert
      model.place_component(definition)
      @native_brush_loop[:last_place_at] = Time.now.to_f if @native_brush_loop
      push_status_to_dialog('Многократная вставка активна. Кликайте в модели, Esc для выхода.')
      true
    rescue StandardError => error
      show_error("\u0412\u0441\u0442\u0430\u0432\u043a\u0430 \u043a\u0438\u0441\u0442\u044c\u044e", error)
      false
    end

    def set_insert_options(payload = nil)
      data = parse_payload(payload)
      options = normalize_insert_options(data)
      write_insert_options(options)
      Logger.info('Опции вставки обновлены', options)
      push_state_to_dialog
      options
    rescue StandardError => error
      show_error("\u041e\u043f\u0446\u0438\u0438 \u0432\u0441\u0442\u0430\u0432\u043a\u0438", error)
      nil
    end

    def set_insert_option(payload = nil)
      data = parse_payload(payload)
      key = data['key'].to_s
      options = read_insert_options
      return options unless options.key?(key)

      value =
        case key
        when 'random_step_degrees'
          normalize_random_step_degrees(data['value'])
        else
          !!data['value']
        end

      options[key] = value
      write_insert_options(options)
      Logger.info('Опция вставки обновлена', { 'key' => key, 'value' => value })
      push_state_to_dialog
      options
    rescue StandardError => error
      show_error("\u041e\u043f\u0446\u0438\u0438 \u0432\u0441\u0442\u0430\u0432\u043a\u0438", error)
      nil
    end

    def regenerate_preview_item(item_id)
      return unless ensure_storage!

      item = @storage.item_by_id(item_id)
      raise ArgumentError, "\u042d\u043b\u0435\u043c\u0435\u043d\u0442 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d." unless item

      push_status_to_dialog("\u041f\u0435\u0440\u0435\u0441\u043e\u0437\u0434\u0430\u043d\u0438\u0435 \u043f\u0440\u0435\u0432\u044c\u044e: 1/1")
      ok = Services::PreviewRegenerator.regenerate_item(@storage, item) do |skp_path, png_path|
        generate_thumbnail(skp_path, png_path)
      end
      push_status_to_dialog(ok ? "\u0413\u043e\u0442\u043e\u0432\u043e: 1/1" : "\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043f\u0435\u0440\u0435\u0441\u043e\u0437\u0434\u0430\u0442\u044c \u043f\u0440\u0435\u0432\u044c\u044e.")
      push_state_to_dialog
      ok
    rescue StandardError => error
      show_error("\u041f\u0435\u0440\u0435\u0441\u043e\u0437\u0434\u0430\u043d\u0438\u0435 \u043f\u0440\u0435\u0432\u044c\u044e", error)
      false
    end

    def regenerate_previews_category(category_name)
      return unless ensure_storage!

      category = category_name.to_s
      items = @storage.index['items'].select { |item| FS.same_name?(item['category'], category) }
      if items.empty?
        UI.messagebox("\u0412 \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438 \u043d\u0435\u0442 \u044d\u043b\u0435\u043c\u0435\u043d\u0442\u043e\u0432.")
        return false
      end
      regenerate_preview_collection(items, "\u041f\u0440\u0435\u0432\u044c\u044e \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438")
    rescue StandardError => error
      show_error("\u041f\u0435\u0440\u0435\u0441\u043e\u0437\u0434\u0430\u043d\u0438\u0435 \u043f\u0440\u0435\u0432\u044c\u044e \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438", error)
      false
    end

    def regenerate_previews_all
      return unless ensure_storage!

      items = @storage.index['items']
      if items.empty?
        UI.messagebox("\u0411\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0430 \u043f\u0443\u0441\u0442\u0430.")
        return false
      end
      regenerate_preview_collection(items, "\u041f\u0440\u0435\u0432\u044c\u044e \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0438")
    rescue StandardError => error
      show_error("\u041f\u0435\u0440\u0435\u0441\u043e\u0437\u0434\u0430\u043d\u0438\u0435 \u043f\u0440\u0435\u0432\u044c\u044e \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0438", error)
      false
    end

    def refresh_item_metadata(payload = nil)
      return unless ensure_storage!

      data = parse_payload(payload)
      item_id = data['id'].to_s
      deep = !!data['deep']
      item = @storage.item_by_id(item_id)
      raise ArgumentError, "\u042d\u043b\u0435\u043c\u0435\u043d\u0442 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d." unless item

      update_item_metadata_from_file(item, deep: deep)
      push_state_to_dialog
      true
    rescue StandardError => error
      show_error("\u041e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435 \u043c\u0435\u0442\u0430\u0434\u0430\u043d\u043d\u044b\u0445", error)
      false
    end

    def set_heavy_threshold(payload = nil)
      data = parse_payload(payload)
      value = data['value'].to_i
      value = 200_000 if value <= 0
      Sketchup.write_default(PREFS_NAMESPACE, PREFS_HEAVY_THRESHOLD_KEY, value.to_s)
      push_state_to_dialog
      value
    rescue StandardError => error
      show_error("\u041f\u043e\u0440\u043e\u0433 \u0442\u044f\u0436\u0435\u0441\u0442\u0438", error)
      nil
    end

    def export_pack
      return unless ensure_storage!

      categories = @storage.index['categories']
      default_category = categories.first.to_s
      prompts = [
        "\u0420\u0435\u0436\u0438\u043c",
        "\u041a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u044f (\u0434\u043b\u044f \u0440\u0435\u0436\u0438\u043c\u0430 category)",
        "Zip \u0430\u0440\u0445\u0438\u0432"
      ]
      defaults = ['category', default_category, 'no']
      lists = ['category|favorites', categories.join('|'), 'no|yes']
      result = UI.inputbox(prompts, defaults, lists, "\u042d\u043a\u0441\u043f\u043e\u0440\u0442 pack")
      return unless result

      mode, category, zip_value = result
      destination = choose_library_root(@storage.lib_root)
      return unless destination

      exported = Services::PackTransfer.export_pack(
        storage: @storage,
        mode: mode.to_s,
        category: category.to_s,
        destination_root: destination,
        zip: zip_value.to_s == 'yes'
      )
      zip_text = exported['zip_path'] ? "\nZIP: #{exported['zip_path']}" : ''
      UI.messagebox("\u042d\u043a\u0441\u043f\u043e\u0440\u0442 \u0433\u043e\u0442\u043e\u0432.\n\u042d\u043b\u0435\u043c\u0435\u043d\u0442\u043e\u0432: #{exported['count']}\n\u041f\u0430\u043f\u043a\u0430: #{exported['pack_root']}#{zip_text}")
      exported
    rescue StandardError => error
      show_error("\u042d\u043a\u0441\u043f\u043e\u0440\u0442 pack", error)
      nil
    end

    def import_pack
      return unless ensure_storage!

      path = nil
      if UI.respond_to?(:select_directory)
        path = UI.select_directory(title: "\u0418\u043c\u043f\u043e\u0440\u0442 pack (\u043f\u0430\u043f\u043a\u0430)", directory: @storage.lib_root)
      end
      path ||= UI.openpanel("\u0418\u043c\u043f\u043e\u0440\u0442 pack (zip)", @storage.lib_root, '*.zip')
      return unless path

      result = Services::PackTransfer.import_pack(
        storage: @storage,
        pack_path: path,
        model: Sketchup.active_model,
        dedupe: proc do |source_item|
          source_hash = source_item['content_hash'].to_s.strip.downcase
          !source_hash.empty? && !find_item_by_content_hash(source_hash).nil?
        end,
        on_item: proc do |saved_item, _src_skp|
          update_item_metadata_from_file(saved_item, deep: false)
        end
      )
      push_state_to_dialog
      UI.messagebox("\u0418\u043c\u043f\u043e\u0440\u0442 \u0433\u043e\u0442\u043e\u0432.\n\u0414\u043e\u0431\u0430\u0432\u043b\u0435\u043d\u043e: #{result['imported']}\n\u041f\u0440\u043e\u043f\u0443\u0449\u0435\u043d\u043e: #{result['skipped']}")
      result
    rescue StandardError => error
      show_error("\u0418\u043c\u043f\u043e\u0440\u0442 pack", error)
      nil
    end

    def save_model_definition_to_library(payload = nil)
      return unless ensure_storage!

      data = parse_payload(payload)
      definition_guid = data['definition_guid'].to_s
      definition = definition_by_guid(definition_guid)
      raise ArgumentError, "\u041e\u043f\u0440\u0435\u0434\u0435\u043b\u0435\u043d\u0438\u0435 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d\u043e." unless definition

      categories = @storage.index['categories']
      default_category = data['category'].to_s.strip.empty? ? (categories.first || "\u041e\u0431\u0449\u0430\u044f") : data['category'].to_s
      default_name = definition.name.to_s.strip
      default_name = "\u041a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442" if default_name.empty?

      result = prompt_save_selected_data(
        default_category: default_category,
        default_name: default_name,
        default_tags: data['tags'].to_s
      )
      return nil unless result

      category, name, description, tags_input = result
      source = definition.respond_to?(:group?) && definition.group? ? 'group' : 'component'
      dedupe = resolve_dedup_for_definition(definition, fallback_name: name)
      return nil unless dedupe
      saved = @storage.save_definition!(
        definition,
        source: source,
        category: category,
        display_name: name,
        tags: tags_input,
        description: description,
        content_hash: dedupe['content_hash']
      )
      ensure_item_thumbnail(saved['item'])
      mark_in_model_items_dirty!
      if saved['name_changed']
        UI.messagebox("\u0418\u043c\u044f \u0443\u0436\u0435 \u0435\u0441\u0442\u044c \u0432 \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438.\n\u0421\u043e\u0445\u0440\u0430\u043d\u0435\u043d\u043e \u043a\u0430\u043a: #{saved['final_name']}")
      end
      push_state_to_dialog
      saved
    rescue StandardError => error
      show_error("\u0421\u043e\u0445\u0440\u0430\u043d\u0435\u043d\u0438\u0435 \u0438\u0437 \"\u0412 \u043c\u043e\u0434\u0435\u043b\u0438\"", error)
      nil
    end

    def select_all_model_definition_instances(definition_guid)
      definition = definition_by_guid(definition_guid)
      raise ArgumentError, "\u041e\u043f\u0440\u0435\u0434\u0435\u043b\u0435\u043d\u0438\u0435 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d\u043e." unless definition

      count = Services::ModelDefinitions.select_all_instances(definition)
      UI.messagebox("\u0412\u044b\u0434\u0435\u043b\u0435\u043d\u043e \u044d\u043a\u0437\u0435\u043c\u043f\u043b\u044f\u0440\u043e\u0432: #{count}")
      count
    rescue StandardError => error
      show_error("\u0412\u044b\u0431\u043e\u0440 \u0432\u0441\u0435\u0445 \u0432 \u043c\u043e\u0434\u0435\u043b\u0438", error)
      0
    end

    def replace_selection_with_library_item(item_id)
      return unless ensure_storage!

      item = @storage.item_by_id(item_id)
      raise ArgumentError, "\u042d\u043b\u0435\u043c\u0435\u043d\u0442 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d." unless item

      skp_path = FS.to_full_path(@storage.lib_root, item['skp_rel_path'])
      raise ArgumentError, "\u0424\u0430\u0439\u043b \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d: #{skp_path}" unless File.file?(skp_path)

      model = Sketchup.active_model
      definition = Compat.load_definition_from_file(
        skp_path,
        definitions: model.definitions,
        notify_user: true,
        context: 'replace_selection',
        library_path: @storage.lib_root
      )
      definition = ensure_component_definition_for_insert(definition)
      summary = Services::Replacer.replace_selection(definition, model)
      @storage.touch_last_used!(item['id'])
      mark_in_model_items_dirty!
      push_state_to_dialog
      show_replace_summary(summary)
      summary
    rescue ArgumentError => error
      UI.messagebox(error.message)
      nil
    rescue StandardError => error
      show_error("\u0417\u0430\u043c\u0435\u043d\u0430 \u0432\u044b\u0434\u0435\u043b\u0435\u043d\u043d\u043e\u0433\u043e", error)
      nil
    end

    def replace_selection_with_model_definition(definition_guid)
      definition = definition_by_guid(definition_guid)
      raise ArgumentError, "\u041e\u043f\u0440\u0435\u0434\u0435\u043b\u0435\u043d\u0438\u0435 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d\u043e." unless definition

      summary = Services::Replacer.replace_selection(definition)
      mark_in_model_items_dirty!
      show_replace_summary(summary)
      summary
    rescue ArgumentError => error
      UI.messagebox(error.message)
      nil
    rescue StandardError => error
      show_error("\u0417\u0430\u043c\u0435\u043d\u0430 \u0432\u044b\u0434\u0435\u043b\u0435\u043d\u043d\u043e\u0433\u043e", error)
      nil
    end

    def open_item_folder(item_id)
      return unless ensure_storage!

      item = @storage.item_by_id(item_id)
      raise ArgumentError, "\u042d\u043b\u0435\u043c\u0435\u043d\u0442 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d." unless item

      full_path = FS.to_full_path(@storage.lib_root, item['skp_rel_path'])
      folder = File.dirname(full_path)
      system('explorer', folder.tr('/', '\\'))
      true
    rescue StandardError => error
      show_error("\u041e\u0442\u043a\u0440\u044b\u0442\u0438\u0435 \u043f\u0430\u043f\u043a\u0438", error)
      false
    end

    def reveal_item_file(item_id)
      return unless ensure_storage!

      item = @storage.item_by_id(item_id)
      raise ArgumentError, "\u042d\u043b\u0435\u043c\u0435\u043d\u0442 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d." unless item

      full_path = FS.to_full_path(@storage.lib_root, item['skp_rel_path']).tr('/', '\\')
      system('explorer', "/select,#{full_path}")
      true
    rescue StandardError => error
      show_error("\u041f\u043e\u043a\u0430\u0437 \u0444\u0430\u0439\u043b\u0430 \u0432 \u043f\u0430\u043f\u043a\u0435", error)
      false
    end

    def toggle_pinned_category(payload = nil)
      data = parse_payload(payload)
      return unless ensure_storage!

      category = data['category'].to_s
      return if category.strip.empty?

      categories = @storage.index['categories']
      canonical = categories.find { |name| FS.same_name?(name, category) }
      raise ArgumentError, "\u041a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u044f \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d\u0430." unless canonical

      pinned = normalized_pinned_categories(categories)
      has_explicit_value = data.key?('pinned')
      is_currently_pinned = pinned.any? { |name| FS.same_name?(name, canonical) }
      should_pin = has_explicit_value ? !!data['pinned'] : !is_currently_pinned

      if should_pin
        if is_currently_pinned
          return pinned
        end
        if pinned.length >= MAX_PINNED_CATEGORIES
          UI.messagebox("\u041c\u043e\u0436\u043d\u043e \u0437\u0430\u043a\u0440\u0435\u043f\u0438\u0442\u044c \u043d\u0435 \u0431\u043e\u043b\u0435\u0435 #{MAX_PINNED_CATEGORIES} \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0439.")
          return pinned
        end
        pinned << canonical
      else
        pinned.reject! { |name| FS.same_name?(name, canonical) }
      end

      write_pinned_categories(pinned)
      push_state_to_dialog
      pinned
    rescue StandardError => error
      show_error("\u0417\u0430\u043a\u0440\u0435\u043f\u043b\u0435\u043d\u0438\u0435 \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438", error)
      nil
    end

    # JS сообщает о выборе карточки. Храним фокус для следующего refresh.
    def select_item(payload = nil)
      # Выбор карточки обрабатывается на стороне UI.
      # Здесь не меняем @focus_item_id, чтобы не было принудительного
      # переключения фильтра/категории после вставки по двойному клику.
      true
    rescue StandardError
      false
    end

    def start_brush(item_id)
      if array_layout_active?
        UI.messagebox('Инструмент "Раскладка" активен. Завершите его (Enter/Esc), затем запускайте кисть.')
        return false
      end
      start_brush_item(item_id)
    end

    def replace_selection(item_id)
      replace_selection_with_library_item(item_id)
    end

    def replace_selection_model(definition_guid)
      replace_selection_with_model_definition(definition_guid)
    end

    def replace_library_item_from_selection(payload = nil)
      return unless ensure_storage!
      if array_layout_active?
        UI.messagebox('Инструмент "Раскладка" активен. Завершите его (Enter/Esc), затем выполните замену элемента библиотеки.')
        return false
      end

      data = parse_payload(payload)
      item_id =
        if data.is_a?(Hash) && !data['id'].to_s.strip.empty?
          data['id'].to_s
        else
          payload.to_s
        end
      success = false
      context = library_item_replacement_context(item_id, show_message: true)
      return false unless context

      item = context['item']
      entity = context['entity']
      return false unless confirm_library_item_replace!(item)

      push_status_to_dialog('Замена элемента...')

      definition = nil
      source = replace_source_from_entity(entity)
      with_definition_from_selection_entity(entity) do |prepared_definition, prepared_source|
        definition = prepared_definition
        source = prepared_source
      end
      raise 'Не удалось подготовить выделенный объект для сохранения.' unless definition

      content_hash = build_temp_content_hash(definition)
      metadata = Services::Metadata.quick_metadata(definition, nil)
      replaced_item = @storage.replace_item_definition!(
        item['id'],
        definition,
        source: source,
        metadata: metadata,
        content_hash: content_hash
      )
      if content_hash.to_s.strip.empty?
        replaced_skp_path = FS.to_full_path(@storage.lib_root, replaced_item['skp_rel_path'])
        fallback_hash = compute_content_hash(replaced_skp_path)
        @storage.set_content_hash!(replaced_item['id'], fallback_hash) if fallback_hash
      end

      rename_from_selected = prompt_rename_replaced_item(definition.name.to_s)
      if rename_from_selected
        @storage.edit_item!(item['id'], { 'name' => definition.name.to_s })
      end

      preview_ok = replace_item_preview_safely(item)
      update_item_metadata_from_file(item, deep: false)
      @storage.touch_last_used!(item['id'])
      mark_in_model_items_dirty!
      push_state_to_dialog
      push_status_to_dialog("Готово: #{Time.now.strftime('%H:%M')}")
      UI.messagebox('Геометрия обновлена, но превью не удалось пересоздать. Оставлено старое превью.') unless preview_ok
      success = true
      true
    rescue ArgumentError => error
      puts("[ComponentLibraryBrowser] #{error.class}: #{error.message}")
      UI.messagebox(error.message)
      false
    rescue StandardError => error
      puts("[ComponentLibraryBrowser] #{error.class}: #{error.message}")
      show_error('Замена элемента библиотеки', error)
      false
    ensure
      push_status_to_dialog('') unless success
    end

    def update_item_fields(payload = nil)
      data = parse_payload(payload)
      return unless ensure_storage!

      result = @storage.edit_item!(data['id'], data)
      if result['name_changed']
        UI.messagebox("\u0418\u043c\u044f \u0443\u0436\u0435 \u0435\u0441\u0442\u044c \u0432 \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438.\n\u0421\u043e\u0445\u0440\u0430\u043d\u0435\u043d\u043e \u043a\u0430\u043a: #{result['final_name']}")
      end
      push_state_to_dialog
      result
    rescue StandardError => error
      show_error("\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0435 \u044d\u043b\u0435\u043c\u0435\u043d\u0442\u0430", error)
      nil
    end

    def regenerate_thumbnail(item_id)
      regenerate_preview_item(item_id)
    end

    def open_folder(item_id)
      open_item_folder(item_id)
    end

    def show_in_folder(item_id)
      reveal_item_file(item_id)
    end

    def copy_path(item_id)
      return nil unless ensure_storage!

      item = @storage.item_by_id(item_id)
      return nil unless item

      FS.to_full_path(@storage.lib_root, item['skp_rel_path'])
    rescue StandardError
      nil
    end

    def modeltab_save_to_library(payload = nil)
      save_model_definition_to_library(payload)
    end

    def modeltab_select_all(definition_guid)
      select_all_model_definition_instances(definition_guid)
    end

    def start_array_layout
      @win_array_controller&.cancel if @win_array_controller&.session_active?
      @array_controller ||= ArrayLayout::ArrayController.new(self)
      @array_controller.launch
    rescue StandardError => error
      show_error('Раскладка', error)
      false
    end

    def start_win_array_layout
      @array_controller&.cancel if @array_controller&.session_active?
      @win_array_controller ||= ArrayLayout::WinArrayController.new(self)
      @win_array_controller.launch
    rescue StandardError => error
      show_error('Раскладка окон', error)
      false
    end

    def read_brick_layout_session_params
      data = @brick_layout_session_params
      return nil unless data.is_a?(Hash)

      data.dup
    rescue StandardError
      nil
    end

    def write_brick_layout_session_params(params)
      @brick_layout_session_params = params.is_a?(Hash) ? params.dup : {}
      true
    rescue StandardError
      false
    end

    def read_array_session_params
      read_brick_layout_session_params
    end

    def write_array_session_params(params)
      write_brick_layout_session_params(params)
    end

    def read_window_layout_session_params
      data = @window_layout_session_params
      return nil unless data.is_a?(Hash)

      data.dup
    rescue StandardError
      nil
    end

    def write_window_layout_session_params(params)
      data = params.is_a?(Hash) ? params : {}
      @window_layout_session_params = {
        'count_x' => data['count_x'].to_i,
        'count_y' => data['count_y'].to_i,
        'axis_spacing_mm' => data['axis_spacing_mm'].to_f,
        'floor_height_mm' => data['floor_height_mm'].to_f
      }
      true
    rescue StandardError
      false
    end

    def read_win_array_session_params
      read_window_layout_session_params
    end

    def write_win_array_session_params(params)
      write_window_layout_session_params(params)
    end

    def reload_plugin!
      close_live_plugin_sessions_before_reload

      plugin_dir = __dir__
      reload_paths = [
        'fs.rb',
        'storage.rb',
        'logger.rb',
        'compat.rb',
        'services/model_definitions.rb',
        'services/replacer.rb',
        'services/metadata.rb',
        'services/preview_regenerator.rb',
        'services/pack_transfer.rb',
        'services/updater.rb',
        'tools/pick_source_tool.rb',
        'tools/layout_geometry.rb',
        'tools/array_tool.rb',
        'tools/window_placement.rb',
        'tools/brick_layout_tool.rb',
        'tools/window_layout_tool.rb',
        'array/array_controller.rb',
        'array/win_array_controller.rb',
        'main.rb'
      ]
      raise 'Reload manifest drift detected' unless reload_paths == RuntimeManifest::RELOAD_PATHS

      RuntimeManifest.absolute_reload_paths(plugin_dir).each { |path| load path }

      Sketchup.status_text = 'Component Library Browser Ruby code reloaded. Restart SketchUp after installing an update with locked files.'
      true
    rescue StandardError => error
      show_error('Перезагрузка плагина', error)
      false
    end

    def check_updates
      result = Updater.check_for_updates
      show_update_dialog(result)
      true
    rescue StandardError => error
      show_error('Проверка обновлений', error)
      false
    end

    def apply_update_with_reload
      check_updates
    end

    def show_update_dialog(result)
      result ||= { 'error' => 'Не удалось проверить обновления. Проверьте подключение к интернету.' }
      available = !!result['available']
      current_version = result['current_version'].to_s
      latest_version = result['latest_version'].to_s
      summary =
        if result['error']
          "Ошибка проверки: #{result['error']}"
        elsif available
          "Доступно обновление: v#{current_version} → v#{latest_version}"
        else
          "Установлена последняя версия: v#{current_version}"
        end
      update_button = available ? '<button class="primary" type="button" onclick="sketchup.install_update()">Обновить</button>' : ''
      dialog = UI::HtmlDialog.new(
        dialog_title: 'Обновление Component Library Browser', preferences_key: 'DraleComponentLibraryBrowserUpdate',
        style: UI::HtmlDialog::STYLE_DIALOG, resizable: false, width: 390, height: 180
      )
      dialog.set_html(<<~HTML)
        <!doctype html><meta charset="utf-8"><style>body{margin:0;padding:20px;font:13px/1.45 Segoe UI,Arial;color:#20242b;background:#fff}p{margin:0 0 14px}#update-status{min-height:20px;color:#5a6470}.actions{display:flex;justify-content:flex-end;gap:8px}button{padding:7px 14px;border:1px solid #c9ced6;border-radius:5px;background:#fff}button.primary{background:#2463eb;color:#fff;border-color:#2463eb}</style><p>#{CGI.escapeHTML(summary)}</p><p id="update-status"></p><div class="actions">#{update_button}<button type="button" onclick="sketchup.cancel_update()">Отмена</button></div>
      HTML
      dialog.add_action_callback('cancel_update') { dialog.close; @update_dialog = nil }
      dialog.add_action_callback('install_update') do
        next unless available

        dialog.execute_script("document.getElementById('update-status').textContent='Подготовка обновления…';")
        schedule_update_install(dialog, result)
      end
      @update_dialog = dialog
      dialog.show
    end

    def schedule_update_install(dialog, update)
      UI.start_timer(0, false) { install_update_from_dialog(dialog, update) }
    rescue StandardError
      install_update_from_dialog(dialog, update)
    end

    def install_update_from_dialog(dialog, update)
      result = Updater.download_and_apply_update(update: update, on_status: ->(text) { set_update_dialog_status(dialog, text) })
      if result['success']
        set_update_dialog_status(dialog, 'Обновление установлено. Перезагрузка плагина…')
        Updater.send(:reload_plugin!)
      elsif result['restart_required']
        set_update_dialog_status(dialog, 'Обновление подготовлено. Требуется перезапуск SketchUp.')
      else
        set_update_dialog_status(dialog, "Ошибка обновления: #{result['error'] || result['message']}")
      end
    rescue StandardError => error
      set_update_dialog_status(dialog, "Ошибка обновления: #{error.message}")
    end

    def set_update_dialog_status(dialog, text)
      escaped = JSON.generate(text.to_s)
      dialog.execute_script("var s=document.getElementById('update-status');if(s)s.textContent=#{escaped};")
    end

    def schedule_background_update_check
      UI.start_timer(5.0, false) do
        background_update_check
      end
    rescue StandardError
    end

    def background_update_check
      result = Updater.check_for_updates(background: true)
      return unless result.is_a?(Hash) && result['available']

      Logger.info("Фоновое обнаружение обновления: v#{result['current_version']} → v#{result['latest_version']}")
    end

    def array_pick_from_library(item_id)
      # Dispatch to whichever array tool is currently active.
      if @win_array_controller&.session_active?
        return @win_array_controller.pick_from_library(item_id)
      end
      return false unless @array_controller

      @array_controller.pick_from_library(item_id)
    rescue StandardError => error
      show_error('Выбор элемента для раскладки', error)
      false
    end

    def select_array_layout_from_selection
      model = Sketchup.active_model
      return 0 unless model

      array_id = selected_array_id_from_selection(model)
      if array_id.to_s.empty?
        UI.messagebox('Выберите элемент раскладки, чтобы найти весь набор.')
        return 0
      end

      matches = find_entities_by_array_id(model, array_id)
      if matches.empty?
        UI.messagebox('Элементы выбранной раскладки не найдены.')
        return 0
      end

      model.selection.clear
      model.selection.add(matches)
      matches.length
    rescue StandardError => error
      show_error('Выделение раскладки', error)
      0
    end

    def delete_array_layout_from_selection
      model = Sketchup.active_model
      return 0 unless model
      operation_started = false

      array_id = selected_array_id_from_selection(model)
      if array_id.to_s.empty?
        UI.messagebox('Выберите элемент раскладки для удаления.')
        return 0
      end

      matches = find_entities_by_array_id(model, array_id)
      if matches.empty?
        UI.messagebox('Элементы выбранной раскладки не найдены.')
        return 0
      end

      confirmed = yes_no?("Удалить раскладку целиком?\nЭлементов: #{matches.length}")
      return 0 unless confirmed

      deleted = 0
      model.start_operation('Удалить раскладку', true)
      operation_started = true
      matches.each do |entity|
        next unless entity && entity.valid?

        entity.erase!
        deleted += 1
      end
      model.commit_operation
      deleted
    rescue StandardError => error
      model = Sketchup.active_model
      model.abort_operation if model && operation_started
      show_error('Удаление раскладки', error)
      0
    end

    def set_array_library_pick_mode(enabled, message = '')
      @array_library_pick_mode = !!enabled
      @array_library_pick_message = message.to_s
      push_state_to_dialog if @dialog && @dialog.visible?
      true
    rescue StandardError
      false
    end

    def set_array_tool_active(enabled)
      @array_tool_active = !!enabled
      push_state_to_dialog if @dialog && @dialog.visible?
      true
    rescue StandardError
      false
    end

    # Вызывается observer-ом при добавлении сущности в entities.
    def handle_native_brush_element_added(entity)
      loop_state = @native_brush_loop
      return unless loop_state
      return unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
      return unless entity.valid?
      model = Sketchup.active_model
      return unless model
      return unless loop_state[:waiting_for_insert]

      inserted_definition =
        if entity.respond_to?(:definition)
          entity.definition
        else
          nil
        end
      return unless inserted_definition

      expected_id = loop_state[:definition_id].to_s
      inserted_id = definition_identifier(inserted_definition).to_s
      return unless definition_matches_loop?(inserted_definition, loop_state, expected_id, inserted_id)

      loop_state[:waiting_for_insert] = false
      loop_state[:last_insert_at] = Time.now.to_f
      loop_state[:placed_count] = loop_state[:placed_count].to_i + 1
      loop_state[:used] = true
      defer_native_brush_insert_finalize(entity, loop_state[:generation], loop_state[:continuous])
    rescue StandardError
      # ignore observer errors
    end

    private

    def start_native_brush_loop(definition, item_id:, continuous:)
      stop_native_brush_loop(clear_status: false)

      @native_brush_generation = @native_brush_generation.to_i + 1
      @native_brush_loop = {
        definition: definition,
        definition_id: definition_identifier(definition),
        item_id: item_id.to_s,
        continuous: !!continuous,
        generation: @native_brush_generation,
        waiting_for_insert: false,
        used: false,
        placed_count: 0,
        last_place_at: Time.now.to_f,
        last_insert_at: 0.0
      }

      @native_brush_entities_observer ||= NativeBrushEntitiesObserver.new(self)
      @native_brush_observed_entities = nil
      attach_native_brush_entities_observer
      start_native_brush_watchdog
      Logger.info(
        'Запуск цикла вставки',
        {
          'item_id' => item_id.to_s,
          'continuous' => !!continuous,
          'generation' => @native_brush_generation.to_i
        }
      )
    end

    def arm_native_brush_wait_for_insert
      return unless @native_brush_loop

      @native_brush_loop[:waiting_for_insert] = true
    end

    def schedule_native_brush_restart(generation, delay = 0.08)
      stop_native_brush_restart_timer

      @native_brush_restart_timer = UI.start_timer(delay.to_f, false) do
        @native_brush_restart_timer = nil
        restart_native_brush_cycle(generation)
      end
    rescue StandardError
      @native_brush_restart_timer = nil
    end

    def stop_native_brush_restart_timer
      return unless @native_brush_restart_timer

      UI.stop_timer(@native_brush_restart_timer)
      @native_brush_restart_timer = nil
    rescue StandardError
      @native_brush_restart_timer = nil
    end

    def restart_native_brush_cycle(generation = nil)
      loop_state = @native_brush_loop
      return unless loop_state
      return if generation && loop_state[:generation].to_i != generation.to_i

      model = Sketchup.active_model
      return stop_native_brush_loop unless model

      definition = loop_state[:definition]
      return stop_native_brush_loop unless definition && definition.valid?

      tool_name = model.tools.active_tool_name.to_s.downcase
      if tool_name.include?('component') || tool_name.include?('компонент')
        schedule_native_brush_restart(loop_state[:generation], 0.08)
        return
      end

      attach_native_brush_entities_observer
      arm_native_brush_wait_for_insert
      model.place_component(definition)
      loop_state[:last_place_at] = Time.now.to_f
    rescue StandardError
      stop_native_brush_loop
    end

    def attach_native_brush_entities_observer
      return unless @native_brush_loop

      model = Sketchup.active_model
      return unless model
      entities = model.active_entities
      return unless entities
      return if @native_brush_observed_entities.equal?(entities)

      if @native_brush_observed_entities
        @native_brush_observed_entities.remove_observer(@native_brush_entities_observer)
      end
      entities.add_observer(@native_brush_entities_observer)
      @native_brush_observed_entities = entities
    rescue StandardError
      # ignore observer re-attach issues
    end

    def start_native_brush_watchdog
      stop_native_brush_watchdog
      @native_brush_watchdog_timer = UI.start_timer(0.35, true) do
        monitor_native_brush_loop
      end
    end

    def stop_native_brush_watchdog
      return unless @native_brush_watchdog_timer

      UI.stop_timer(@native_brush_watchdog_timer)
      @native_brush_watchdog_timer = nil
    rescue StandardError
      @native_brush_watchdog_timer = nil
    end

    def monitor_native_brush_loop
      loop_state = @native_brush_loop
      return unless loop_state

      model = Sketchup.active_model
      return stop_native_brush_loop unless model

      attach_native_brush_entities_observer
      now = Time.now.to_f
      tool_name = model.tools.active_tool_name.to_s.downcase
      component_tool_active = tool_name.include?('component') || tool_name.include?('компонент')

      # Если пользователь завершил вставку (Esc/смена инструмента), через короткую паузу
      # выключаем цикл, чтобы он не перезапускался в другом сценарии.
      idle_after_place = now - loop_state[:last_place_at]
      idle_after_insert = now - loop_state[:last_insert_at]
      waiting_for_insert = !!loop_state[:waiting_for_insert]
      should_stop =
        if waiting_for_insert
          # Пока пользователь целится первым/следующим кликом, не прерываем цикл слишком рано.
          idle_after_place > 120.0
        else
          idle_after_place > 0.9 && idle_after_insert > 0.5
        end

      if !component_tool_active && should_stop
        stop_native_brush_loop
      end
    rescue StandardError
      stop_native_brush_loop
    end

    def defer_native_brush_insert_finalize(entity, generation, continuous)
      UI.start_timer(0.0, false) do
        loop_state = @native_brush_loop
        next unless loop_state
        next unless loop_state[:generation].to_i == generation.to_i

        apply_insert_options_after_place(entity, read_insert_options)
        if continuous
          schedule_native_brush_restart(generation, 0.02)
        else
          stop_native_brush_loop(clear_status: true)
        end
      end
    rescue StandardError
      # ignore timer scheduling failures
    end

    def definition_matches_loop?(inserted_definition, loop_state, expected_id, inserted_id)
      expected_definition = loop_state[:definition]
      return true if expected_definition && inserted_definition == expected_definition
      return true if !expected_id.empty? && expected_id == inserted_id

      expected_path = expected_definition.respond_to?(:path) ? expected_definition.path.to_s : ''
      inserted_path = inserted_definition.respond_to?(:path) ? inserted_definition.path.to_s : ''
      if !expected_path.empty? && !inserted_path.empty?
        begin
          return true if File.expand_path(expected_path).casecmp?(File.expand_path(inserted_path))
        rescue StandardError
          # ignore path comparison failures
        end
      end

      expected_name = expected_definition.respond_to?(:name) ? expected_definition.name.to_s : ''
      inserted_name = inserted_definition.respond_to?(:name) ? inserted_definition.name.to_s : ''
      !expected_name.empty? && expected_name == inserted_name
    rescue StandardError
      false
    end

    def stop_native_brush_loop(clear_status: true)
      loop_state = @native_brush_loop

      if @native_brush_observed_entities && @native_brush_entities_observer
        @native_brush_observed_entities.remove_observer(@native_brush_entities_observer)
      end
      @native_brush_observed_entities = nil
      @native_brush_loop = nil
      stop_native_brush_restart_timer
      stop_native_brush_watchdog
      finalize_native_insert_usage(loop_state)
      if loop_state && !loop_state[:used]
        Logger.info(
          'Цикл вставки остановлен без размещения',
          {
            'item_id' => loop_state[:item_id].to_s,
            'continuous' => !!loop_state[:continuous],
            'generation' => loop_state[:generation].to_i
          }
        )
      end
      push_status_to_dialog('') if clear_status
    rescue StandardError
      @native_brush_observed_entities = nil
      @native_brush_loop = nil
      stop_native_brush_restart_timer
      stop_native_brush_watchdog
      finalize_native_insert_usage(loop_state)
      push_status_to_dialog('') if clear_status
    end

    def finalize_native_insert_usage(loop_state)
      return unless loop_state.is_a?(Hash)
      return unless loop_state[:used]
      return unless @storage

      item_id = loop_state[:item_id].to_s
      return if item_id.empty?

      @storage.touch_last_used!(item_id)
      push_state_to_dialog
      Logger.info(
        'Завершена вставка',
        {
          'item_id' => item_id,
          'continuous' => !!loop_state[:continuous],
          'placed_count' => loop_state[:placed_count].to_i
        }
      )
    rescue StandardError => error
      Logger.error('Не удалось завершить обновление после вставки', error, { 'item_id' => loop_state[:item_id].to_s })
    end

    def apply_insert_options_after_place(entity, options)
      return unless entity && entity.valid?
      return unless options.is_a?(Hash)

      model = Sketchup.active_model
      return unless model
      return if opening_component_instance?(entity)

      if options['align_to_normal']
        normal_world = pick_world_normal_for_instance(entity, model)
        if normal_world
          normal_local = normal_world.transform(model.edit_transform.inverse)
          align_instance_zaxis!(entity, normal_local)
        end
      end

      if options['random_quadrant']
        axis = entity.transformation.zaxis
        axis = Geom::Vector3d.new(0, 0, 1) if axis.nil? || axis.length <= 0.0001
        origin = entity.transformation.origin
        step = normalize_random_step_degrees(options['random_step_degrees'])
        values = []
        angle = 0
        while angle < 360
          values << angle
          angle += step
        end
        angle = values.sample.to_f.degrees
        entity.transform!(Geom::Transformation.rotation(origin, axis, angle)) if angle.abs > 0.0001
      end

      if options['drop_to_ground']
        move_instance_world_z!(entity, model, -entity.bounds.min.z)
      elsif !options['place_on_surface']
        origin_world = entity.transformation.origin.transform(model.edit_transform)
        move_instance_world_z!(entity, model, -origin_world.z)
      end
    rescue StandardError
      # ignore post-process transform errors
    end

    def opening_component_instance?(entity)
      return false unless entity && entity.valid?
      return false unless entity.respond_to?(:definition)

      definition = entity.definition
      return false unless definition && definition.valid?
      return false unless definition.respond_to?(:behavior)

      behavior = definition.behavior
      return false unless behavior && behavior.respond_to?(:cuts_opening?)

      !!behavior.cuts_opening?
    rescue StandardError
      false
    end

    def move_instance_world_z!(entity, model, delta_world)
      return unless entity && entity.valid? && model

      delta = delta_world.to_f
      return if delta.abs < 0.0001

      world_move = Geom::Transformation.translation([0, 0, delta])
      edit = model.edit_transform
      local_move = edit.inverse * world_move * edit
      entity.transform!(local_move)
    end

    def pick_world_normal_for_instance(entity, model)
      origin_world = entity.transformation.origin.transform(model.edit_transform)
      zaxis = Geom::Vector3d.new(0, 0, 1)
      rays = [
        [origin_world.offset(zaxis, 1000.0), zaxis.reverse],
        [origin_world.offset(zaxis.reverse, 1000.0), zaxis]
      ]

      rays.each do |ray_origin, ray_dir|
        hit = model.raytest([ray_origin, ray_dir], false)
        next unless hit && hit[1].is_a?(Array)

        normal = world_normal_from_ray_path(hit[1])
        return normal if normal && normal.length > 0.0
      end
      nil
    rescue StandardError
      nil
    end

    def world_normal_from_ray_path(path)
      tr = Geom::Transformation.new
      face = nil

      Array(path).each do |element|
        if element.is_a?(Sketchup::Face)
          face = element
          break
        end
        tr = tr * element.transformation if element.respond_to?(:transformation)
      end
      return nil unless face

      normal = face.normal.transform(tr)
      return nil unless normal && normal.length > 0.0

      normal.normalize
      normal
    rescue StandardError
      nil
    end

    def align_instance_zaxis!(entity, target_zaxis_local)
      return unless entity && entity.valid?
      return unless target_zaxis_local && target_zaxis_local.length > 0.0

      zaxis = target_zaxis_local.clone
      zaxis.normalize!
      xaxis = entity.transformation.xaxis
      xaxis = entity.transformation.yaxis if xaxis.parallel?(zaxis)
      xaxis = xaxis.cross(zaxis)
      xaxis = Geom::Vector3d.new(1, 0, 0).cross(zaxis) if xaxis.length < 0.0001
      return if xaxis.length < 0.0001

      xaxis.normalize!
      yaxis = zaxis.cross(xaxis)
      yaxis.normalize!
      origin = entity.transformation.origin

      new_tr = Geom::Transformation.axes(origin, xaxis, yaxis, zaxis)
      delta = entity.transformation.inverse * new_tr
      entity.transform!(delta)
    rescue StandardError
      # ignore alignment errors
    end

    def prompt_save_selected_data(default_category:, default_name:, default_tags:)
      categories = @storage.index['categories'].dup
      categories << default_category unless default_category.to_s.strip.empty? || categories.any? { |category| FS.same_name?(category, default_category) }
      result = UI.inputbox(
        ["\u041a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u044f"],
        [default_category.to_s],
        [(categories.sort + [ADD_CATEGORY_OPTION]).join('|')],
        "\u0421\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c \u0432 \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0443"
      )
      return nil unless result

      selected_category = result[0].to_s
      if selected_category.to_s == ADD_CATEGORY_OPTION
        new_category = prompt_new_category_name
        return nil unless new_category

        current_category = new_category
        metadata = prompt_save_metadata(default_name: default_name, default_tags: default_tags)
        return nil unless metadata

        return [current_category, *metadata]
      end

      metadata = prompt_save_metadata(default_name: default_name, default_tags: default_tags)
      return nil unless metadata

      [selected_category, *metadata]
    end

    def prompt_save_metadata(default_name:, default_tags:)
      result = UI.inputbox(
        ["\u0418\u043c\u044f", "\u041e\u043f\u0438\u0441\u0430\u043d\u0438\u0435", "\u0422\u0435\u0433\u0438 (\u0447\u0435\u0440\u0435\u0437 \u0437\u0430\u043f\u044f\u0442\u0443\u044e)"],
        [default_name.to_s, '', default_tags.to_s],
        ['', '', ''],
        "\u041c\u0435\u0442\u0430\u0434\u0430\u043d\u043d\u044b\u0435 \u043a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442\u0430"
      )
      result && [result[0].to_s, result[1].to_s, result[2].to_s]
    end

    def save_group_as_component_to_library(group, category:, name:, description:, tags:)
      model = Sketchup.active_model
      temp_group = nil
      temp_component = nil

      model.start_operation('CLB Save Group As Component', true)
      begin
        temp_group = group.copy
        temp_component = temp_group.to_component
        dedupe = resolve_dedup_for_definition(temp_component.definition, fallback_name: name)
        unless dedupe
          temp_component.erase! if temp_component.valid?
          model.commit_operation
          return nil
        end
        saved = @storage.save_definition!(
          temp_component.definition,
          source: 'group',
          category: category,
          display_name: name,
          tags: tags,
          description: description,
          content_hash: dedupe['content_hash']
        )
        temp_component.erase! if temp_component.valid?
        model.commit_operation
        saved
      rescue StandardError
        temp_group.erase! if temp_group && temp_group.valid?
        temp_component.erase! if temp_component && temp_component.valid?
        model.abort_operation
        raise
      end
    end

    def ensure_component_definition_for_insert(definition)
      return definition unless definition.respond_to?(:group?) && definition.group?

      model = Sketchup.active_model
      temp_instance = nil
      temp_component = nil

      model.start_operation('CLB Convert Group Definition', true)
      begin
        temp_instance = model.active_entities.add_instance(definition, Geom::Transformation.new)
        if temp_instance.is_a?(Sketchup::Group)
          temp_component = temp_instance.to_component
          converted_definition = temp_component.definition
          temp_component.erase! if temp_component.valid?
        else
          converted_definition = definition
          temp_instance.erase! if temp_instance.valid?
        end
        model.commit_operation
        converted_definition
      rescue StandardError
        temp_component.erase! if temp_component && temp_component.valid?
        temp_instance.erase! if temp_instance && temp_instance.valid?
        model.abort_operation
        definition
      end
    end

    def prompt_new_category_name
      loop do
        result = UI.inputbox(["\u0418\u043c\u044f \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438"], [''], [''], "\u0414\u043e\u0431\u0430\u0432\u0438\u0442\u044c \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u044e")
        return nil unless result

        name = result[0].to_s.strip
        if name.empty?
          UI.messagebox("\u0418\u043c\u044f \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438 \u043d\u0435 \u043c\u043e\u0436\u0435\u0442 \u0431\u044b\u0442\u044c \u043f\u0443\u0441\u0442\u044b\u043c.")
          next
        end

        added = @storage.add_category!(name)
        unless added
          UI.messagebox("\u0422\u0430\u043a\u0430\u044f \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u044f \u0443\u0436\u0435 \u0435\u0441\u0442\u044c.")
          next
        end

        push_state_to_dialog
        return name
      end
    rescue StandardError => error
      show_error("\u0414\u043e\u0431\u0430\u0432\u043b\u0435\u043d\u0438\u0435 \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438", error)
      nil
    end

    def setup_commands
      return if @commands

      @commands = {}
      @commands[:open] = build_command(
        menu_text: "\u041e\u0442\u043a\u0440\u044b\u0442\u044c \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0443...",
        tooltip: "\u041e\u0442\u043a\u0440\u044b\u0442\u044c \u043e\u043a\u043d\u043e \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0438",
        status: "\u041e\u0442\u043a\u0440\u044b\u0442\u044c \u043e\u043a\u043d\u043e \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0438 \u043a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442\u043e\u0432.",
        icon_prefix: 'open'
      ) { open_library }

      @commands[:save] = build_command(
        menu_text: "\u0421\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c \u0432\u044b\u0434\u0435\u043b\u0435\u043d\u043d\u043e\u0435...",
        tooltip: "\u0421\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c \u0432\u044b\u0431\u0440\u0430\u043d\u043d\u0443\u044e \u0413\u0440\u0443\u043f\u043f\u0443/\u041a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442",
        status: "\u0421\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c \u0432\u044b\u0431\u0440\u0430\u043d\u043d\u044b\u0439 \u043e\u0431\u044a\u0435\u043a\u0442 \u0432 \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0443.",
        icon_prefix: 'save'
      ) { save_selected_to_library }

      @commands[:array] = build_command(
        menu_text: 'Раскладка кирпича...',
        tooltip: 'Раскладка кирпича/элементов в группу с предпросмотром',
        status: 'Запустить инструмент раскладки кирпича/элементов с предпросмотром.',
        icon_prefix: 'brick'
      ) { start_array_layout }

      @commands[:win_array] = build_command(
        menu_text: 'Раскладка окон...',
        tooltip: 'Раскладка окон по грани стены с предпросмотром',
        status: 'Запустить инструмент раскладки окон по грани стены.',
        icon_prefix: 'window'
      ) { start_win_array_layout }

      @commands[:array_select_layout] = build_command(
        menu_text: 'Выделить раскладку (по array_id)',
        tooltip: 'Выделить все элементы раскладки по выбранному объекту',
        status: 'Выделить весь набор раскладки по array_id.'
      ) { select_array_layout_from_selection }

      @commands[:array_delete_layout] = build_command(
        menu_text: 'Удалить раскладку (по array_id)',
        tooltip: 'Удалить все элементы раскладки по выбранному объекту',
        status: 'Удалить весь набор раскладки по array_id.'
      ) { delete_array_layout_from_selection }

      @commands[:settings] = build_command(
        menu_text: "\u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438...",
        tooltip: "\u0412\u044b\u0431\u0440\u0430\u0442\u044c \u043f\u0430\u043f\u043a\u0443 \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0438",
        status: "\u0418\u0437\u043c\u0435\u043d\u0438\u0442\u044c \u043f\u0430\u043f\u043a\u0443 \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0438.",
        icon_prefix: 'settings'
      ) { open_settings }

      @commands[:scan] = build_command(
        menu_text: "\u0421\u043a\u0430\u043d\u0438\u0440\u043e\u0432\u0430\u0442\u044c \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0443...",
        tooltip: "\u0421\u043a\u0430\u043d\u0438\u0440\u043e\u0432\u0430\u0442\u044c \u043f\u0430\u043f\u043a\u0438 \u0438 \u043f\u0435\u0440\u0435\u0441\u043e\u0431\u0440\u0430\u0442\u044c \u0438\u043d\u0434\u0435\u043a\u0441",
        status: "\u041f\u0440\u043e\u0441\u043a\u0430\u043d\u0438\u0440\u043e\u0432\u0430\u0442\u044c \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0443 \u043d\u0430 \u0434\u0438\u0441\u043a\u0435."
      ) { scan_library }

      @commands[:export_pack] = build_command(
        menu_text: "\u042d\u043a\u0441\u043f\u043e\u0440\u0442 pack...",
        tooltip: "\u042d\u043a\u0441\u043f\u043e\u0440\u0442 \u043f\u043e\u0434\u0431\u043e\u0440\u043a\u0438 \u0432 pack",
        status: "\u042d\u043a\u0441\u043f\u043e\u0440\u0442 \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438/\u0438\u0437\u0431\u0440\u0430\u043d\u043d\u043e\u0433\u043e \u0432 pack."
      ) { export_pack }

      @commands[:import_pack] = build_command(
        menu_text: "\u0418\u043c\u043f\u043e\u0440\u0442 pack...",
        tooltip: "\u0418\u043c\u043f\u043e\u0440\u0442 pack \u0432 \u0442\u0435\u043a\u0443\u0449\u0443\u044e \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0443",
        status: "\u0418\u043c\u043f\u043e\u0440\u0442 \u044d\u043b\u0435\u043c\u0435\u043d\u0442\u043e\u0432 \u0438\u0437 pack."
      ) { import_pack }

      @commands[:open_log] = build_command(
        menu_text: "\u041e\u0442\u043a\u0440\u044b\u0442\u044c \u043b\u043e\u0433...",
        tooltip: "\u041e\u0442\u043a\u0440\u044b\u0442\u044c \u0444\u0430\u0439\u043b \u043b\u043e\u0433\u0430 \u043e\u0442\u043b\u0430\u0434\u043a\u0438",
        status: "\u041f\u043e\u043a\u0430\u0437\u0430\u0442\u044c \u043b\u043e\u0433 \u043f\u043b\u0430\u0433\u0438\u043d\u0430."
      ) { open_log_file }

@commands[:reload_plugin] = build_command(
        menu_text: 'Перезагрузить плагин',
        tooltip: 'Перезагрузить Component Library Browser без перезапуска SketchUp',
        status: 'Перезагрузить Ruby-код плагина Component Library Browser.'
      ) { reload_plugin! }

      @commands[:check_updates] = build_command(
        menu_text: 'Проверить обновления...',
        tooltip: 'Проверить наличие новой версии на GitHub',
        status: 'Проверить доступные обновления плагина на GitHub.'
      ) { check_updates }

      @commands[:apply_update] = build_command(
        menu_text: 'Установить обновление...',
        tooltip: 'Скачать и установить последнюю версию с GitHub',
        status: 'Скачать обновление с GitHub, установить и перезагрузить плагин.'
      ) { apply_update_with_reload }
    end

    def build_command(menu_text:, tooltip:, status:, icon_prefix: nil)
      command = UI::Command.new(menu_text) { yield }
      command.menu_text = menu_text
      command.tooltip = tooltip
      command.status_bar_text = status
      if icon_prefix
        command.small_icon = icon_path("#{icon_prefix}_16.png")
        command.large_icon = icon_path("#{icon_prefix}_24.png")
      end
      command
    end

    def setup_menu
      return if @menu_ready

      menu = UI.menu('Extensions').add_submenu(MENU_ROOT)
      menu.add_item(@commands[:open])
      menu.add_item(@commands[:save])
      menu.add_item(@commands[:array])
      menu.add_item(@commands[:win_array])
      menu.add_item(@commands[:array_select_layout])
      menu.add_item(@commands[:array_delete_layout])
      menu.add_item(@commands[:settings])
      menu.add_item(@commands[:scan])
      menu.add_separator
      menu.add_item(@commands[:export_pack])
      menu.add_item(@commands[:import_pack])
      menu.add_separator
menu.add_item(@commands[:open_log])
      menu.add_separator
      menu.add_item(@commands[:check_updates])
      menu.add_item(@commands[:apply_update])
      menu.add_item(@commands[:reload_plugin])
      @menu_ready = true
    end

    def setup_toolbar
      return if @toolbar

      @toolbar = UI::Toolbar.new(TOOLBAR_NAME)
      @toolbar.add_item(@commands[:open])
      @toolbar.add_item(@commands[:save])
      @toolbar.add_item(@commands[:array])
      @toolbar.add_item(@commands[:win_array])
      @toolbar.restore
    end

    def close_live_plugin_sessions_before_reload
      @array_controller&.cancel if @array_controller&.respond_to?(:cancel)
      @win_array_controller&.cancel if @win_array_controller&.respond_to?(:cancel)
      @array_controller = nil
      @win_array_controller = nil

      if @dialog && @dialog.respond_to?(:close)
        @dialog.close
      end
      @dialog = nil
    rescue StandardError
      @array_controller = nil
      @win_array_controller = nil
      @dialog = nil
    end

    def setup_context_menu
      return if @context_menu_ready

      UI.add_context_menu_handler do |menu|
        if valid_selection_for_save?
          menu.add_item(CONTEXT_MENU_TEXT) do
            save_selected_to_library
          end
        end

        model = Sketchup.active_model
        next unless model

        array_id = selected_array_id_from_selection(model)
        next if array_id.to_s.empty?

        menu.add_separator
        menu.add_item('Выделить раскладку (по array_id)') do
          select_array_layout_from_selection
        end
        menu.add_item('Удалить раскладку (по array_id)') do
          delete_array_layout_from_selection
        end
      end

      @context_menu_ready = true
    end

    def valid_selection_for_save?
      model = Sketchup.active_model
      return false unless model

      selection = model.selection
      return false unless selection && selection.count == 1

      entity = selection.first
      entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
    end

    def selected_array_id_from_selection(model = Sketchup.active_model)
      return '' unless model

      selection = model.selection
      return '' unless selection && selection.count.positive?

      entity = selection.first
      return '' unless entity && entity.valid? && entity.respond_to?(:get_attribute)

      entity.get_attribute(ARRAY_ATTR_DICTIONARY, ARRAY_ATTR_ID_KEY).to_s
    rescue StandardError
      ''
    end

    def find_entities_by_array_id(model, array_id)
      return [] unless model

      id = array_id.to_s.strip
      return [] if id.empty?

      result = []
      roots = [model.entities]
      active = model.active_entities
      roots << active if active && !roots.any? { |entry| entry.equal?(active) }
      roots.each { |entities| collect_array_entities_in_container(entities, id, result) }
      result.uniq
    rescue StandardError
      []
    end

    def collect_array_entities_in_container(entities, array_id, result)
      return unless entities

      entities.each do |entity|
        next unless entity && entity.valid?

        if entity.respond_to?(:get_attribute)
          current_id = entity.get_attribute(ARRAY_ATTR_DICTIONARY, ARRAY_ATTR_ID_KEY).to_s
          result << entity if !current_id.empty? && current_id == array_id
        end

        if entity.is_a?(Sketchup::Group)
          collect_array_entities_in_container(entity.entities, array_id, result)
        end
      end
    rescue StandardError
      # ignore traversal failures
    end

    def ensure_storage!
      return @storage if @storage

      root = read_saved_root
      if root.to_s.strip.empty? || !File.directory?(root)
        UI.messagebox("\u0412\u044b\u0431\u0435\u0440\u0438\u0442\u0435 \u043f\u0430\u043f\u043a\u0443 \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0438, \u0447\u0442\u043e\u0431\u044b \u043f\u0440\u043e\u0434\u043e\u043b\u0436\u0438\u0442\u044c.")
        root = choose_library_root(root)
      end
      return nil if root.to_s.strip.empty?

      configure_storage_root(root, prompt_scan: true)
    end

    def ensure_storage_for_refresh!
      root = @storage ? @storage.lib_root : read_saved_root
      if root.to_s.strip.empty? || !File.directory?(root)
        UI.messagebox('Папка библиотеки не настроена')
        return nil
      end

      unless @storage && same_path_ci?(@storage.lib_root, root)
        configure_storage_root(root, prompt_scan: false)
      end
      @storage
    end

    def perform_library_scan(show_summary_message:)
      storage = ensure_storage_for_refresh!
      return 0 unless storage

      before_items = storage.index['items']
      before_ids = before_items.map { |item| item['id'].to_s }
      push_status_to_dialog('Сканирование...')

      count = storage.scan_library! do |skp_path, png_path|
        generate_thumbnail(skp_path, png_path)
      end

      items = storage.index['items']
      total = items.length
      items.each_with_index do |item, idx|
        push_status_to_dialog("Обновление метаданных: #{idx + 1}/#{total}")
        update_item_metadata_from_file(item, deep: false)
      end

      after_ids = @storage.index['items'].map { |item| item['id'].to_s }
      added = (after_ids - before_ids).length
      removed = (before_ids - after_ids).length
      status_text = format_scan_done_status(added, removed)
      push_status_to_dialog(status_text)

      push_state_to_dialog
      UI.messagebox("Сканирование завершено.\nНайдено элементов: #{count}") if show_summary_message
      count
    rescue StandardError => error
      show_error('Сканирование библиотеки', error)
      0
    end

    def format_scan_done_status(added, removed)
      added = added.to_i
      removed = removed.to_i
      return 'Готово' if added.zero? && removed.zero?

      "Готово: +#{added}, -#{removed}"
    end

    def same_path_ci?(left, right)
      File.expand_path(left.to_s).casecmp?(File.expand_path(right.to_s))
    rescue StandardError
      false
    end

    def configure_storage_root(root, prompt_scan:)
      root = File.expand_path(root)
      FileUtils.mkdir_p(root)

      index_exists = File.file?(FS.index_path(root))
      has_components = Dir.glob(File.join(FS.categories_root(root), '*', '*.skp')).any?

      @storage = Storage.new(root)
      @in_model_items_cache = []
      @in_model_items_dirty = true
      Sketchup.write_default(PREFS_NAMESPACE, PREFS_LIB_ROOT_KEY, root)

      if prompt_scan && !index_exists && has_components
        if yes_no?("\u0418\u043d\u0434\u0435\u043a\u0441 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d, \u043d\u043e \u0432 \u043f\u0430\u043f\u043a\u0435 \u0435\u0441\u0442\u044c \u043a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442\u044b:\n#{root}\n\n\u0412\u044b\u043f\u043e\u043b\u043d\u0438\u0442\u044c \u0441\u043a\u0430\u043d\u0438\u0440\u043e\u0432\u0430\u043d\u0438\u0435?")
          @storage.scan_library! do |skp_path, png_path|
            generate_thumbnail(skp_path, png_path)
          end
        end
      end

      @storage
    end

    def choose_library_root(default_dir = nil)
      default_dir = default_dir.to_s
      default_dir = Dir.home if default_dir.empty?

      if UI.respond_to?(:select_directory)
        UI.select_directory(title: "\u0412\u044b\u0431\u0435\u0440\u0438\u0442\u0435 \u043f\u0430\u043f\u043a\u0443 \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0438", directory: default_dir)
      else
        selected_file = UI.openpanel("\u0412\u044b\u0431\u0435\u0440\u0438\u0442\u0435 \u043b\u044e\u0431\u043e\u0439 \u0444\u0430\u0439\u043b \u0432 \u043f\u0430\u043f\u043a\u0435 \u0431\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0438", default_dir, '*.*')
        selected_file ? File.dirname(selected_file) : nil
      end
    end

    def read_saved_root
      Sketchup.read_default(PREFS_NAMESPACE, PREFS_LIB_ROOT_KEY, '')
    end

    def show_dialog
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      @dialog = UI::HtmlDialog.new(DIALOG_OPTIONS)
      @dialog.set_file(File.join(__dir__, 'ui', 'index.html'))
      @dialog.set_on_closed do
        Logger.info('Окно библиотеки закрыто')
        detach_dialog_selection_observer
        @dialog = nil
      end

      register_dialog_callbacks(@dialog)
      attach_dialog_selection_observer
      @dialog.show
      Logger.info('Окно библиотеки открыто')
    end

    def register_dialog_callbacks(dialog)
      dialog.add_action_callback('ready') do |_action_context, _payload|
        push_state_to_dialog
      end

      dialog.add_action_callback('get_state') do |_action_context, _payload|
        push_state_to_dialog
      end

      dialog.add_action_callback('refresh_in_model') do |_action_context, _payload|
        refresh_in_model_items!
      end

      dialog.add_action_callback('refresh_selection_state') do |_action_context, _payload|
        push_selection_state_to_dialog
      end

      dialog.add_action_callback('js_error') do |_action_context, payload|
        data = parse_payload(payload)
        Logger.error(
          'Ошибка в HtmlDialog',
          nil,
          {
            'message' => data['message'],
            'source' => data['source'],
            'line' => data['line'],
            'column' => data['column'],
            'stack' => data['stack']
          }
        )
      end

      dialog.add_action_callback('select_item') do |_action_context, payload|
        select_item(payload)
      end

      dialog.add_action_callback('array_pick_from_library') do |_action_context, item_id|
        array_pick_from_library(item_id)
      end

      dialog.add_action_callback('insert_item') do |_action_context, item_id|
        insert_item(item_id)
      end

      dialog.add_action_callback('start_brush_item') do |_action_context, item_id|
        start_brush_item(item_id)
      end

      dialog.add_action_callback('start_brush') do |_action_context, item_id|
        start_brush(item_id)
      end

      dialog.add_action_callback('replace_with_library_item') do |_action_context, item_id|
        replace_selection_with_library_item(item_id)
      end

      dialog.add_action_callback('replace_selection') do |_action_context, item_id|
        replace_selection(item_id)
      end

      dialog.add_action_callback('replace_library_item_from_selection') do |_action_context, payload|
        replace_library_item_from_selection(payload)
      end

      dialog.add_action_callback('save_in_model_definition') do |_action_context, payload|
        save_model_definition_to_library(payload)
      end

      dialog.add_action_callback('modeltab_save_to_library') do |_action_context, payload|
        modeltab_save_to_library(payload)
      end

      dialog.add_action_callback('replace_with_model_definition') do |_action_context, definition_guid|
        replace_selection_with_model_definition(definition_guid)
      end

      dialog.add_action_callback('replace_selection_model') do |_action_context, definition_guid|
        replace_selection_model(definition_guid)
      end

      dialog.add_action_callback('select_all_in_model') do |_action_context, definition_guid|
        select_all_model_definition_instances(definition_guid)
      end

      dialog.add_action_callback('modeltab_select_all') do |_action_context, definition_guid|
        modeltab_select_all(definition_guid)
      end

      dialog.add_action_callback('item_open_folder') do |_action_context, item_id|
        open_item_folder(item_id)
      end

      dialog.add_action_callback('open_folder') do |_action_context, item_id|
        open_folder(item_id)
      end

      dialog.add_action_callback('item_reveal_file') do |_action_context, item_id|
        reveal_item_file(item_id)
      end

      dialog.add_action_callback('show_in_folder') do |_action_context, item_id|
        show_in_folder(item_id)
      end

      dialog.add_action_callback('copy_path') do |_action_context, item_id|
        copy_path(item_id)
      end

      dialog.add_action_callback('toggle_pinned_category') do |_action_context, payload|
        toggle_pinned_category(payload)
      end

      dialog.add_action_callback('set_insert_options') do |_action_context, payload|
        set_insert_options(payload)
      end

      dialog.add_action_callback('set_insert_option') do |_action_context, payload|
        set_insert_option(payload)
      end

      dialog.add_action_callback('regenerate_preview_item') do |_action_context, item_id|
        regenerate_preview_item(item_id)
      end

      dialog.add_action_callback('regenerate_thumbnail') do |_action_context, item_id|
        regenerate_thumbnail(item_id)
      end

      dialog.add_action_callback('regenerate_previews_category') do |_action_context, category_name|
        regenerate_previews_category(category_name)
      end

      dialog.add_action_callback('regenerate_previews_all') do |_action_context, _payload|
        regenerate_previews_all
      end

      dialog.add_action_callback('refresh_item_metadata') do |_action_context, payload|
        refresh_item_metadata(payload)
      end

      dialog.add_action_callback('set_heavy_threshold') do |_action_context, payload|
        set_heavy_threshold(payload)
      end

      dialog.add_action_callback('export_pack') do |_action_context, _payload|
        export_pack
      end

      dialog.add_action_callback('import_pack') do |_action_context, _payload|
        import_pack
      end

      dialog.add_action_callback('toggle_favorite') do |_action_context, payload|
        data = parse_payload(payload)
        return unless ensure_storage!

        @storage.toggle_favorite!(data['id'], data['value'])
        push_state_to_dialog
      rescue StandardError => error
        show_error("\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0435 \u0438\u0437\u0431\u0440\u0430\u043d\u043d\u043e\u0433\u043e", error)
      end

      dialog.add_action_callback('edit_item') do |_action_context, payload|
        update_item_fields(payload)
      end

      dialog.add_action_callback('update_item_fields') do |_action_context, payload|
        update_item_fields(payload)
      end

      dialog.add_action_callback('delete_item') do |_action_context, item_id|
        return unless ensure_storage!

        item = @storage.item_by_id(item_id)
        raise ArgumentError, "\u042d\u043b\u0435\u043c\u0435\u043d\u0442 \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d." unless item

        confirmed = yes_no?("\u0423\u0434\u0430\u043b\u0438\u0442\u044c \u044d\u043b\u0435\u043c\u0435\u043d\u0442 \"#{item['name']}\"?\n\u0424\u0430\u0439\u043b\u044b \u0431\u0443\u0434\u0443\u0442 \u0443\u0434\u0430\u043b\u0435\u043d\u044b \u0441 \u0434\u0438\u0441\u043a\u0430.")
        next unless confirmed

        @storage.delete_item!(item['id'])
        push_state_to_dialog
      rescue StandardError => error
        show_error("\u0423\u0434\u0430\u043b\u0435\u043d\u0438\u0435 \u044d\u043b\u0435\u043c\u0435\u043d\u0442\u0430", error)
      end

      dialog.add_action_callback('category_add') do |_action_context, name|
        return unless ensure_storage!

        @storage.add_category!(name)
        push_state_to_dialog
      rescue StandardError => error
        show_error("\u0414\u043e\u0431\u0430\u0432\u043b\u0435\u043d\u0438\u0435 \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438", error)
      end

      dialog.add_action_callback('category_rename') do |_action_context, payload|
        data = parse_payload(payload)
        return unless ensure_storage!

        @storage.rename_category!(data['old'], data['new'])
        push_state_to_dialog
      rescue StandardError => error
        show_error("\u041f\u0435\u0440\u0435\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435 \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438", error)
      end

      dialog.add_action_callback('category_delete') do |_action_context, name|
        return unless ensure_storage!

        confirmed = yes_no?("\u0423\u0434\u0430\u043b\u0438\u0442\u044c \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u044e \"#{name}\"?\n\u041c\u043e\u0436\u043d\u043e \u0442\u043e\u043b\u044c\u043a\u043e \u0435\u0441\u043b\u0438 \u043e\u043d\u0430 \u043f\u0443\u0441\u0442\u0430\u044f.")
        next unless confirmed

        @storage.delete_category!(name)
        push_state_to_dialog
      rescue StandardError => error
        show_error("\u0423\u0434\u0430\u043b\u0435\u043d\u0438\u0435 \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438", error)
      end

      dialog.add_action_callback('save_selected') do |_action_context, payload|
        save_selected_to_library(payload)
      end

      dialog.add_action_callback('scan_library') do |_action_context, _payload|
        scan_library
      end

      dialog.add_action_callback('refresh_index_only') do |_action_context, _payload|
        refresh_index_only
      end

      dialog.add_action_callback('scan_library_folder') do |_action_context, _payload|
        scan_library_folder
      end

      dialog.add_action_callback('open_settings') do |_action_context, _payload|
        open_settings
      end

      dialog.add_action_callback('change_library_root') do |_action_context, _payload|
        change_library_root
      end

      dialog.add_action_callback('create_new_library_root') do |_action_context, _payload|
        create_new_library_root
      end
    end

    def update_item_metadata_from_file(item, deep: false)
      return unless item.is_a?(Hash)

      skp_path = FS.to_full_path(@storage.lib_root, item['skp_rel_path'])
      return unless File.file?(skp_path)

      definition, loaded_now = load_definition_for_analysis(skp_path)
      return unless definition

      metadata = Services::Metadata.quick_metadata(definition, skp_path)
      if deep
        metadata = metadata.merge(Services::Metadata.deep_metadata(definition))
      end
      @storage.update_item_metadata!(item['id'], metadata)

      if item['content_hash'].to_s.strip.empty?
        hash = compute_content_hash(skp_path)
        @storage.set_content_hash!(item['id'], hash) if hash
      end
    ensure
      unload_definition_after_analysis(definition, loaded_now)
    end

    def load_definition_for_analysis(skp_path)
      model = Sketchup.active_model
      definitions = model.definitions
      existing = definitions.find do |definition|
        next false if definition.path.to_s.empty?
        File.expand_path(definition.path).casecmp?(File.expand_path(skp_path))
      rescue StandardError
        false
      end

      return [existing, false] if existing

      [Compat.load_definition_from_file(
        skp_path,
        definitions: definitions,
        context: 'analysis',
        library_path: @storage ? @storage.lib_root : nil
      ), true]
    rescue StandardError
      [nil, false]
    end

    def unload_definition_after_analysis(definition, loaded_now)
      return unless loaded_now
      return unless definition && definition.valid?
      return unless definition.instances.empty?

      Sketchup.active_model.definitions.remove(definition)
    rescue StandardError
      # ignore cleanup failures
    end

    def compute_content_hash(path)
      Digest::SHA1.file(path).hexdigest
    rescue StandardError
      nil
    end

    def resolve_dedup_for_definition(definition, fallback_name:)
      # Быстрый выход: если в индексе нет ни одного валидного content_hash,
      # запуск временного save_copy и SHA1 только тормозит интерактивное сохранение.
      items = @storage.index['items']
      has_known_hashes = items.any? { |item| !item['content_hash'].to_s.strip.empty? }
      return { 'content_hash' => nil } unless has_known_hashes

      content_hash = build_temp_content_hash(definition)
      return { 'content_hash' => nil } unless content_hash

      duplicate = find_item_by_content_hash(content_hash)
      return { 'content_hash' => content_hash } unless duplicate

      title = duplicate['name'].to_s.strip.empty? ? fallback_name.to_s : duplicate['name'].to_s
      choice = yes_no_cancel?("\u041f\u043e\u0445\u043e\u0436\u0435, \u0442\u0430\u043a\u043e\u0439 \u043a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442 \u0443\u0436\u0435 \u0435\u0441\u0442\u044c: \"#{title}\".\n\n\u0414\u0430 = \u041e\u0442\u043a\u0440\u044b\u0442\u044c \u0441\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u044e\u0449\u0438\u0439\n\u041d\u0435\u0442 = \u0421\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c \u043a\u0430\u043a \u043a\u043e\u043f\u0438\u044e\n\u041e\u0442\u043c\u0435\u043d\u0430 = \u041e\u0442\u043c\u0435\u043d\u0438\u0442\u044c")
      if choice == :yes
        @focus_item_id = duplicate['id']
        push_state_to_dialog
        return nil
      end
      return nil if choice == :cancel

      { 'content_hash' => content_hash }
    rescue StandardError
      { 'content_hash' => nil }
    end

    def build_temp_content_hash(definition)
      tmp_dir = Dir.mktmpdir('clb_hash_')
      tmp_skp = File.join(tmp_dir, 'candidate.skp')
      saved = Compat.save_definition_to_file(
        definition,
        tmp_skp,
        purpose: :hash_temp,
        library_path: @storage ? @storage.lib_root : nil
      )
      unless saved
        notify_dedup_unavailable_once if !definition.respond_to?(:save_copy)
        return nil
      end
      compute_content_hash(tmp_skp)
    ensure
      FileUtils.remove_entry(tmp_dir) if defined?(tmp_dir) && tmp_dir && File.directory?(tmp_dir)
    end

    def notify_dedup_unavailable_once
      @dedup_unavailable_notice_shown ||= false
      return if @dedup_unavailable_notice_shown

      @dedup_unavailable_notice_shown = true
      UI.messagebox('Дедупликация по содержимому недоступна в SketchUp 2021. Сохранение в библиотеку продолжится без проверки дублей.')
    rescue StandardError
      # ignore UI failures
    end

    def find_item_by_content_hash(content_hash)
      return nil if content_hash.to_s.strip.empty?

      content_hash = content_hash.to_s.downcase
      items = @storage.index['items']
      found = items.find { |item| item['content_hash'].to_s.downcase == content_hash }
      return found if found

      items.each do |item|
        next unless item['content_hash'].to_s.strip.empty?

        skp_path = FS.to_full_path(@storage.lib_root, item['skp_rel_path'])
        next unless File.file?(skp_path)

        current_hash = compute_content_hash(skp_path)
        next unless current_hash

        @storage.set_content_hash!(item['id'], current_hash)
        return item if current_hash == content_hash
      end

      nil
    end

    def generate_thumbnail(skp_path, png_path)
      model = Sketchup.active_model
      defs = model.definitions
      existing = defs.find do |definition|
        next false if definition.path.to_s.empty?
        File.expand_path(definition.path).casecmp?(File.expand_path(skp_path))
      rescue StandardError
        false
      end

      loaded_now = false
      definition = existing
      unless definition
        definition = Compat.load_definition_from_file(
          skp_path,
          definitions: defs,
          context: 'generate_thumbnail',
          library_path: @storage ? @storage.lib_root : nil
        )
        loaded_now = true
      end

      definition.save_thumbnail(png_path)
      FS.compact_png_thumbnail(png_path, 256)

      if loaded_now && definition.instances.empty?
        defs.remove(definition)
      end
      true
    rescue StandardError
      # Leave scan running even if one thumbnail fails.
      false
    end

    def ensure_item_thumbnail(item)
      return unless item.is_a?(Hash)

      skp_full = FS.to_full_path(@storage.lib_root, item['skp_rel_path'])
      png_full = FS.to_full_path(@storage.lib_root, item['thumb_rel_path'])
      needs_regen = !File.file?(png_full) || File.size(png_full).to_i <= 0
      return unless needs_regen

      generate_thumbnail(skp_full, png_full)
    rescue StandardError
      # Ignore thumbnail fallback errors, item is still saved.
    end

    def push_state_to_dialog
      return unless @dialog
      return unless ensure_storage!

      state = build_ui_state
      script = "window.ComponentLibrary && window.ComponentLibrary.setState(#{JSON.generate(state)});"
      @dialog.execute_script(script)
      @focus_item_id = nil
    rescue StandardError => error
      show_error("\u041e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435 UI", error)
    end

    def build_ui_state
      index = @storage.index
      items = index['items'].map do |item|
        skp_full = FS.to_full_path(@storage.lib_root, item['skp_rel_path'])
        folder_full = File.dirname(skp_full)
        thumb_full = FS.to_full_path(@storage.lib_root, item['thumb_rel_path'])
        thumb_url =
          if File.file?(thumb_full)
            stamp = begin
              ((File.mtime(thumb_full).to_f * 1000).to_i).to_s
            rescue StandardError
              Time.now.to_i.to_s
            end
            "#{file_url(thumb_full)}?v=#{stamp}"
          else
            nil
          end

        item.merge(
          'kind' => 'library',
          'description' => item['description'].to_s,
          'thumb_url' => thumb_url,
          'skp_full_path' => skp_full,
          'folder_full_path' => folder_full
        )
      end

      in_model_items = cached_in_model_items
      pinned_categories = normalized_pinned_categories(index['categories'])

      {
        'lib_root' => @storage.lib_root,
        'legacy_read_only' => @storage.legacy_read_only?,
        'categories' => index['categories'].sort,
        'pinned_categories' => pinned_categories,
        'items' => items,
        'in_model_items' => in_model_items,
        'all_tags' => @storage.all_tags,
        'recent_limit' => RECENT_LIMIT,
        'insert_options' => read_insert_options,
        'status_text' => @status_line.to_s,
        'heavy_faces_threshold' => read_heavy_threshold,
        'focus_item_id' => @focus_item_id,
        'array_pick_mode' => !!@array_library_pick_mode,
        'array_pick_message' => @array_library_pick_message.to_s,
        'array_tool_active' => !!@array_tool_active,
        'selection_state' => build_selection_state
      }
    end

    def push_selection_state_to_dialog
      return unless @dialog

      script = "window.ComponentLibrary && window.ComponentLibrary.setSelectionState(#{JSON.generate(build_selection_state)});"
      @dialog.execute_script(script)
    rescue StandardError
      # ignore selection state update failures
    end

    def build_selection_state
      model = Sketchup.active_model
      selection = model ? model.selection : nil
      count = selection ? selection.count.to_i : 0
      {
        'count' => count,
        'replace_library_from_selection_allowed' => selection_valid_for_library_replace?(selection)
      }
    rescue StandardError
      { 'count' => 0, 'replace_library_from_selection_allowed' => false }
    end

    def array_layout_active?
      return true if @array_tool_active
      return true if @win_array_controller&.session_active?

      @array_controller && @array_controller.respond_to?(:session_active?) && @array_controller.session_active?
    rescue StandardError
      false
    end

    def build_in_model_items
      entries = Services::ModelDefinitions.used_definitions(Sketchup.active_model)
      entries.map do |entry|
        definition = entry['definition']
        {
          'kind' => 'in_model',
          'definition_guid' => entry['definition_guid'],
          'name' => entry['name'],
          'instances_count' => entry['instances_count'],
          'category' => "\u0412 \u043c\u043e\u0434\u0435\u043b\u0438",
          'description' => '',
          'tags' => [],
          'thumb_url' => in_model_thumb_url(definition)
        }
      end
    rescue StandardError
      []
    end

    def cached_in_model_items
      return @in_model_items_cache if @in_model_items_cache.is_a?(Array) && !@in_model_items_dirty

      @in_model_items_cache ||= []
    end

    def refresh_in_model_items!
      return unless ensure_storage!

      @in_model_items_cache = build_in_model_items
      @in_model_items_dirty = false
      push_state_to_dialog
      true
    rescue StandardError => error
      show_error("\u041e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435 \"\u0412 \u043c\u043e\u0434\u0435\u043b\u0438\"", error)
      false
    end

    def mark_in_model_items_dirty!
      @in_model_items_dirty = true
    end

    def handle_dialog_selection_changed
      push_selection_state_to_dialog
    end

    def definition_by_guid(definition_guid)
      guid = definition_guid.to_s.strip
      return nil if guid.empty?

      model = Sketchup.active_model
      return nil unless model

      model.definitions.find { |definition| definition_identifier(definition) == guid }
    end

    def definition_identifier(definition)
      return '' unless definition

      if definition.respond_to?(:persistent_id)
        pid = definition.persistent_id.to_i
        return "pid:#{pid}" if pid.positive?
      end

      guid = definition.guid.to_s.strip
      return "guid:#{guid}" unless guid.empty?

      "obj:#{definition.object_id}"
    end

    def in_model_thumb_url(definition)
      return nil unless definition && definition.valid?

      cache_root = File.join(Dir.tmpdir, 'clb_model_previews')
      FileUtils.mkdir_p(cache_root)
      cache_id = safe_definition_cache_id(definition)
      cache_id = "def_#{definition.object_id}" if cache_id.empty?
      filename = "#{cache_id}.png"
      full_path = File.join(cache_root, filename)

      needs_write = !valid_png_file?(full_path)
      write_in_model_thumbnail(definition, full_path) if needs_write
      return nil unless valid_png_file?(full_path)

      file_url(full_path)
    rescue StandardError
      nil
    end

    def write_in_model_thumbnail(definition, full_path)
      # 1) Прямой путь: save_thumbnail на definition.
      begin
        definition.save_thumbnail(full_path)
        FS.compact_png_thumbnail(full_path, 256)
        return true if valid_png_file?(full_path)
      rescue StandardError
        # fallback below
      end

      # 2) Fallback: временный skp и повторная генерация превью.
      tmp_dir = Dir.mktmpdir('clb_model_thumb_')
      tmp_skp = File.join(tmp_dir, "#{safe_definition_cache_id(definition)}.skp")
      saved = Compat.save_definition_to_file(
        definition,
        tmp_skp,
        purpose: :thumbnail_temp,
        library_path: @storage ? @storage.lib_root : nil
      )
      return false unless saved && File.file?(tmp_skp)

      model = Sketchup.active_model
      temp_definition = Compat.load_definition_from_file(
        tmp_skp,
        definitions: model.definitions,
        context: 'in_model_thumbnail',
        library_path: @storage ? @storage.lib_root : nil
      )
      temp_definition = ensure_component_definition_for_insert(temp_definition)
      temp_definition.save_thumbnail(full_path)
      FS.compact_png_thumbnail(full_path, 256)
      model.definitions.remove(temp_definition) if temp_definition && temp_definition.valid? && temp_definition.instances.empty?

      valid_png_file?(full_path)
    ensure
      FileUtils.remove_entry(tmp_dir) if defined?(tmp_dir) && tmp_dir && File.directory?(tmp_dir)
    end

    def valid_png_file?(path)
      return false unless File.file?(path)

      return false if File.size(path).to_i < 16

      signature = File.binread(path, 8)
      signature == "\x89PNG\r\n\x1A\n".b
    rescue StandardError
      false
    end

    def safe_definition_cache_id(definition)
      id = definition_identifier(definition).to_s
      id = 'definition' if id.strip.empty?
      id = id.gsub(/[^a-zA-Z0-9_\-.]/, '_')
      id = 'definition' if id.strip.empty?
      id
    end

    def show_replace_summary(summary)
      return unless summary.is_a?(Hash)

      replaced = summary['replaced'].to_i
      skipped = summary['skipped'].to_i
      UI.messagebox("\u0417\u0430\u043c\u0435\u043d\u0435\u043d\u043e: #{replaced}\n\u041f\u0440\u043e\u043f\u0443\u0449\u0435\u043d\u043e: #{skipped}")
    end

    def normalized_pinned_categories(categories)
      categories = Array(categories)
      stored = read_pinned_categories
      normalized = stored.map do |stored_name|
        categories.find { |name| FS.same_name?(name, stored_name) }
      end.compact.uniq
      write_pinned_categories(normalized)
      normalized
    end

    def read_pinned_categories
      raw = Sketchup.read_default(PREFS_NAMESPACE, PREFS_PINNED_CATEGORIES_KEY, '[]')
      parsed = JSON.parse(raw.to_s)
      Array(parsed).map { |value| value.to_s.strip }.reject(&:empty?).uniq.first(MAX_PINNED_CATEGORIES)
    rescue StandardError
      []
    end

    def write_pinned_categories(categories)
      values = Array(categories).map { |value| value.to_s.strip }.reject(&:empty?).uniq.first(MAX_PINNED_CATEGORIES)
      Sketchup.write_default(PREFS_NAMESPACE, PREFS_PINNED_CATEGORIES_KEY, JSON.generate(values))
    end

    def default_insert_options
      {
        'place_on_surface' => true,
        'align_to_normal' => false,
        'random_quadrant' => false,
        'drop_to_ground' => false,
        'random_step_degrees' => 90
      }
    end

    def normalize_insert_options(raw)
      data = raw.is_a?(Hash) ? raw : {}
      defaults = default_insert_options
      {
        'place_on_surface' => !!data.fetch('place_on_surface', defaults['place_on_surface']),
        'align_to_normal' => !!data.fetch('align_to_normal', defaults['align_to_normal']),
        'random_quadrant' => !!data.fetch('random_quadrant', defaults['random_quadrant']),
        'drop_to_ground' => !!data.fetch('drop_to_ground', defaults['drop_to_ground']),
        'random_step_degrees' => normalize_random_step_degrees(data.fetch('random_step_degrees', defaults['random_step_degrees']))
      }
    end

    def normalize_random_step_degrees(value)
      step = value.to_i
      step.between?(1, 360) ? step : 90
    rescue StandardError
      90
    end

    def read_insert_options
      return @insert_options_cache if @insert_options_cache.is_a?(Hash) && !@insert_options_cache.empty?

      raw = Sketchup.read_default(PREFS_NAMESPACE, PREFS_INSERT_OPTIONS_KEY, '{}')
      parsed = JSON.parse(raw.to_s)
      @insert_options_cache = normalize_insert_options(default_insert_options.merge(parsed))
    rescue StandardError
      @insert_options_cache = default_insert_options
    end

    def write_insert_options(options)
      normalized = normalize_insert_options(options)
      @insert_options_cache = normalized
      Sketchup.write_default(PREFS_NAMESPACE, PREFS_INSERT_OPTIONS_KEY, JSON.generate(normalized))
    end

    def read_heavy_threshold
      value = Sketchup.read_default(PREFS_NAMESPACE, PREFS_HEAVY_THRESHOLD_KEY, '200000').to_i
      value.positive? ? value : 200_000
    rescue StandardError
      200_000
    end

    def regenerate_preview_collection(items, title)
      items = Array(items)
      total = items.length
      return false if total.zero?

      done = 0
      items.each_with_index do |item, idx|
        push_status_to_dialog("#{title}: #{idx + 1}/#{total}")
        ok = Services::PreviewRegenerator.regenerate_item(@storage, item) do |skp_path, png_path|
          generate_thumbnail(skp_path, png_path)
        end
        done += 1 if ok
      end
      push_status_to_dialog("Готово: #{done}/#{total}")
      push_state_to_dialog
      true
    end

    def push_status_to_dialog(text)
      @status_line = text.to_s
      return unless @dialog

      script = "window.ComponentLibrary && window.ComponentLibrary.setStatus(#{JSON.generate(@status_line)});"
      @dialog.execute_script(script)
    rescue StandardError
      # ignore status update failures
    end

    def file_url(path)
      normalized = File.expand_path(path).tr('\\', '/')
      parts = normalized.split('/')
      return "file:///#{normalized}" if parts.empty?

      drive = parts.shift
      encoded = [drive]
      parts.each do |part|
        encoded << CGI.escape(part.to_s).gsub('+', '%20')
      end
      "file:///#{encoded.join('/')}"
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

    def selection_valid_for_library_replace?(selection)
      return false unless selection
      return false unless selection.count == 1

      entity = selection.first
      entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
    rescue StandardError
      false
    end

    def library_item_replacement_context(item_id, show_message:)
      item = @storage.item_by_id(item_id)
      unless item
        UI.messagebox('Выберите элемент библиотеки для замены.') if show_message
        return nil
      end

      skp_path = FS.to_full_path(@storage.lib_root, item['skp_rel_path'])
      unless File.file?(skp_path)
        message = "Файл элемента не найден: #{skp_path}"
        UI.messagebox(message) if show_message
        raise ArgumentError, message
      end

      entity = selection_entity_for_library_replace(show_message: show_message)
      return nil unless entity

      { 'item' => item, 'entity' => entity, 'skp_path' => skp_path }
    end

    def selection_entity_for_library_replace(show_message:)
      model = Sketchup.active_model
      selection = model ? model.selection : nil
      unless selection && selection.count == 1
        if show_message
          count = selection ? selection.count.to_i : 0
          UI.messagebox("Для замены выберите ровно один объект в модели (Группа или Компонент).\nТекущее выделение: #{count}")
        end
        return nil
      end

      entity = selection.first
      if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        return entity
      end

      UI.messagebox("Поддерживаются только Группа или ComponentInstance.\nТекущий тип: #{entity.class}") if show_message
      nil
    rescue StandardError
      UI.messagebox('Не удалось прочитать выделение модели.') if show_message
      nil
    end

    def confirm_library_item_replace!(item)
      name = item['name'].to_s
      name = 'без имени' if name.strip.empty?
      message = "Заменить элемент библиотеки \"#{name}\" на выделенный объект в модели?\nТеги и категория сохранятся. Файл библиотеки будет перезаписан."
      ok_cancel?(message)
    end

    def replace_source_from_entity(entity)
      entity.is_a?(Sketchup::Group) ? 'group' : 'component'
    end

    def with_definition_from_selection_entity(entity)
      raise ArgumentError, 'Выделение не задано.' unless entity

      if entity.is_a?(Sketchup::ComponentInstance)
        yield(entity.definition, 'component')
        return
      end

      model = Sketchup.active_model
      temp_group = nil
      temp_component = nil
      definition = nil

      model.start_operation('CLB Prepare Group For Replace', true)
      begin
        temp_group = entity.copy
        temp_component = temp_group.to_component
        definition = temp_component.definition
        yield(definition, 'group')
        temp_component.erase! if temp_component && temp_component.valid?
        model.commit_operation
      rescue StandardError
        temp_component.erase! if temp_component && temp_component.valid?
        temp_group.erase! if temp_group && temp_group.valid?
        model.abort_operation
        raise
      ensure
        begin
          if definition && definition.valid? && definition.instances.empty?
            Sketchup.active_model.definitions.remove(definition)
          end
        rescue StandardError
          # ignore cleanup failures
        end
      end
    end

    def replace_item_preview_safely(item)
      skp_path = FS.to_full_path(@storage.lib_root, item['skp_rel_path'])
      png_path = FS.to_full_path(@storage.lib_root, item['thumb_rel_path'])
      tmp_png = "#{png_path}.tmp.png"
      FileUtils.mkdir_p(File.dirname(png_path))

      ok = generate_thumbnail(skp_path, tmp_png)
      return false unless ok && File.file?(tmp_png)

      FileUtils.mv(tmp_png, png_path, force: true)
      true
    rescue StandardError => error
      puts("[ComponentLibraryBrowser] Preview regeneration failed: #{error.class} #{error.message}")
      false
    ensure
      File.delete(tmp_png) if defined?(tmp_png) && tmp_png && File.file?(tmp_png)
    end

    def prompt_rename_replaced_item(default_name)
      normalized_name = default_name.to_s.strip
      return false if normalized_name.empty?

      result = UI.inputbox(
        ['Переименовать по имени выбранного?'],
        ['Нет'],
        ['Нет|Да'],
        'Переименование элемента'
      )
      return false unless result

      result[0].to_s.strip.casecmp?('Да')
    rescue StandardError
      false
    end

    def attach_dialog_selection_observer
      model = Sketchup.active_model
      return unless model

      selection = model.selection
      return unless selection

      @dialog_selection_observer ||= DialogSelectionObserver.new(self)
      detach_dialog_selection_observer
      selection.add_observer(@dialog_selection_observer)
      @dialog_observed_selection = selection
    rescue StandardError
      @dialog_observed_selection = nil
    end

    def detach_dialog_selection_observer
      return unless @dialog_observed_selection && @dialog_selection_observer

      @dialog_observed_selection.remove_observer(@dialog_selection_observer)
      @dialog_observed_selection = nil
    rescue StandardError
      @dialog_observed_selection = nil
    end

    def icon_path(filename)
      File.join(__dir__, 'icons', filename)
    end

    def show_error(scope, error)
      message = "\u041e\u0448\u0438\u0431\u043a\u0430 (#{scope}):\n#{error.message}"
      UI.messagebox(message)
      Logger.error(
        "\u041e\u0448\u0438\u0431\u043a\u0430: #{scope}",
        error,
        Compat.environment_snapshot(library_path: @storage ? @storage.lib_root : nil)
      )
    end

    def yes_no?(message)
      yes_no = Object.const_defined?(:MB_YESNO) ? MB_YESNO : 4
      yes = Object.const_defined?(:IDYES) ? IDYES : 6
      UI.messagebox(message, yes_no) == yes
    end

    def yes_no_cancel?(message)
      yes_no_cancel = Object.const_defined?(:MB_YESNOCANCEL) ? MB_YESNOCANCEL : 3
      yes = Object.const_defined?(:IDYES) ? IDYES : 6
      no = Object.const_defined?(:IDNO) ? IDNO : 7
      result = UI.messagebox(message, yes_no_cancel)
      return :yes if result == yes
      return :no if result == no

      :cancel
    end

    def ok_cancel?(message)
      ok_cancel = Object.const_defined?(:MB_OKCANCEL) ? MB_OKCANCEL : 1
      ok = Object.const_defined?(:IDOK) ? IDOK : 1
      UI.messagebox(message, ok_cancel) == ok
    end
  end
end

unless file_loaded?(__FILE__)
  Drale::ComponentLibraryBrowser.boot!
  file_loaded(__FILE__)
end

