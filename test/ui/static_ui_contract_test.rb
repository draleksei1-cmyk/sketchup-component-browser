# frozen_string_literal: true

require 'json'
require 'minitest/autorun'

class StaticUiContractTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  UI = File.join(ROOT, 'component_library_browser', 'ui')

  def html
    @html ||= File.read(File.join(UI, 'index.html'), encoding: 'UTF-8')
  end

  def js
    @js ||= File.read(File.join(UI, 'app.js'), encoding: 'UTF-8')
  end

  def css
    @css ||= [File.read(File.join(UI, 'styles.css'), encoding: 'UTF-8'), File.read(File.join(UI, 'visibility.css'), encoding: 'UTF-8')].join
  end

  def main
    @main ||= File.read(File.join(ROOT, 'component_library_browser', 'main.rb'), encoding: 'UTF-8')
  end

  def test_realistic_fixture_has_at_least_twelve_library_items
    fixture = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'library-state.json'), encoding: 'UTF-8'))
    assert_operator fixture.fetch('items').length, :>=, 12
  end

  def test_fixture_covers_model_item_callback_shape
    fixture = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'library-state.json'), encoding: 'UTF-8'))
    item = fixture.fetch('in_model_items').first
    assert_equal 'in_model', item.fetch('kind')
    assert_equal 'def-001', item.fetch('definition_guid')
    refute item.key?('id'), 'model items must use definition_guid, not an empty library id'
  end

  def test_harness_stubs_sketchup_before_loading_production_app
    script = File.read(File.join(__dir__, 'test_harness.js'), encoding: 'UTF-8')
    assert_includes script, 'window.sketchup'
    assert_includes script, 'fixtures/library-state.json'
    assert_operator script.index('window.sketchup'), :<, script.index('app.src')
  end

  def test_library_shell_has_required_landmarks_and_safe_cards
    %w[search cards-grid details-drawer primary-insert card-template library-overflow].each do |id|
      assert_match(/id=["']#{Regexp.escape(id)}["']/, html, "missing ##{id}")
    end
    refute_match(/class=["'][^"']*card-(favorite|delete)/, html)
  end

  def test_icon_only_actions_are_not_unicode_glyph_buttons
    html.scan(/<button\b[^>]*>(.*?)<\/button>/m).flatten.each do |contents|
      text = contents.gsub(/<[^>]+>/, '').strip
      refute_match(/\A[★✕✖✚✎⚙↻⋮‹›«»+\-]+\z/, text, "glyph-only action button: #{text.inspect}")
    end
  end

  def test_production_app_exposes_test_bootstrap_guard_and_preserves_core_callbacks
    assert_includes js, '__CLB_TEST_BOOTSTRAP__'
    %w[ready refresh insert_item array_pick_from_library delete_item update_item_fields].each do |callback|
      assert_match(/#{Regexp.escape(callback)}/, js, "missing callback #{callback}")
    end
  end

  def test_canonical_svg_icons_and_toolbar_png_pairs_follow_the_icon_contract
    icon_dir = File.join(ROOT, 'component_library_browser', 'icons')
    required = %w[open save brick window settings array folder pipette check cancel refresh more star close]
    required.each do |name|
      path = File.join(icon_dir, "#{name}.svg")
      assert File.file?(path), "missing canonical SVG #{name}.svg"
      svg = File.read(path, encoding: 'UTF-8')
      assert_match(/viewBox=["']0 0 24 24["']/, svg)
      assert_match(/fill=["']none["']/, svg)
      assert_match(/currentColor/, svg)
      assert_match(/stroke-width=["']1\.75["']/, svg)
      assert_match(/stroke-linecap=["']round["']/, svg)
      assert_match(/stroke-linejoin=["']round["']/, svg)
    end
    main = File.read(File.join(ROOT, 'component_library_browser', 'main.rb'), encoding: 'UTF-8')
    mappings = main.scan(/icon_prefix:\s*'([^']+)'/).flatten.uniq.sort
    png_prefixes = Dir.glob(File.join(icon_dir, '*_{16,24}.png')).map { |path| File.basename(path).sub(/_(16|24)\.png\z/, '') }.uniq.sort
    assert_equal mappings, png_prefixes, 'only mapped toolbar icons get raster pairs'
    mappings.each do |name|
      [16, 24].each do |size|
        png = File.binread(File.join(icon_dir, "#{name}_#{size}.png"), 24)
        assert_equal "\x89PNG\r\n\x1A\n".b, png[0, 8]
        assert_equal size, png[16, 4].unpack1('N')
        assert_equal size, png[20, 4].unpack1('N')
      end
    end
  end

  def test_hidden_dialogs_and_drawer_cannot_be_unhidden_by_layout_css
    assert_includes css, '[hidden]{display:none!important}'
  end

  def test_category_context_menu_exposes_existing_category_callbacks
    %w[category-context-menu category-rename category-delete category-regen category-pin].each do |id|
      assert_match(/id=["']#{Regexp.escape(id)}["']/, html, "missing ##{id}")
    end
    %w[category_rename category_delete regenerate_previews_category toggle_pinned_category].each do |callback|
      assert_match(/#{Regexp.escape(callback)}/, js, "missing callback #{callback}")
    end
  end

  def test_model_item_actions_route_by_definition_guid
    assert_match(/modeltab_save_to_library/, js)
    assert_match(/replace_selection_model/, js)
    assert_match(/modeltab_select_all/, js)
    assert_match(/definition_guid/, js)
  end

  def test_model_item_actions_use_model_semantics
    assert_includes js, 'Сохранить в библиотеку'
    assert_includes html, 'Выбрать все в модели'
    assert_includes html, 'Вставить'
    assert_includes html, 'data-action="select_all_model"'
    refute_match(/data-action=["']select_all_model["'][^>]*>Удалить</, html)
    assert_includes js, 'modeltab_save_to_library'
  end

  def test_ux_pass_keeps_the_library_navigable_and_uses_canonical_action_icons
    assert_match(/id=["']settings-btn["'][^>]*class=["'][^"']*rail-settings-button/, html)
    assert_match(/src=["']\.\.\/icons\/settings\.svg["']/, html)
    assert_match(/src=["']\.\.\/icons\/insert\.svg["']/, html)
    assert_match(/class=["']drawer-primary-actions["']/, html)
    assert_match(/id=["']primary-insert["']/, html)
    assert_match(/id=["']drawer-brush["']/, html)
    assert_includes css, '.rail-settings-button{width:32px;height:32px'
    assert_includes css, '@media(min-width:1180px)'
    assert_includes css, '@media(max-width:1179px)'
    assert_includes css, '.library-card.selected{'
    assert_includes css, 'transform:scale(1.015)'
  end

  def test_ux_pass_has_inline_placement_controls_and_validated_rotation_step
    assert_match(/class=["']placement-option["'][^>]*>\s*<input id=["']opt-surface["']/, html)
    assert_match(/id=["']opt-random-step["'][^>]*type=["']number["'][^>]*min=["']1["'][^>]*max=["']360["'][^>]*value=["']90["']/, html)
    assert_includes css, 'details .placement-option{display:flex;align-items:center'
    assert_includes js, 'setRotationStep'
    assert_includes js, 'random_step_degrees'
  end

  def test_ux_pass_exposes_safe_favorites_and_actionable_legacy_recovery
    %w[legacy-library-notice legacy-create-root legacy-change-root].each { |id| assert_match(/id=["']#{id}["']/, html) }
    assert_includes js, 'card-favorite'
    assert_includes js, 'toggle_favorite'
    assert_includes js, 'create_new_library_root'
    assert_includes main, 'def create_new_library_root'
    assert_includes main, 'legacy_read_only?'
  end

  def test_save_new_category_continues_to_metadata_without_reopening_the_category_picker
    assert_includes main, 'def prompt_save_metadata'
    assert_match(/selected_category\.to_s == ADD_CATEGORY_OPTION.*?current_category = new_category.*?prompt_save_metadata/m, main)
    assert_includes main, 'description: description'
  end

  def test_bootstrap_refresh_and_legacy_root_actions_use_registered_ruby_callbacks
    assert_match(/ruby\("ready"\)/, js)
    assert_match(/ruby\("refresh_index_only"\)/, js)
    assert_match(/add_action_callback\('create_new_library_root'\)/, main)
    assert_match(/create_new_library_root/, main)
    assert_includes main, 'same_path_ci?(selected_root, current_root)'
    assert_includes main, 'Новая папка библиотеки должна быть пустой.'
  end

  def test_overflow_menu_binds_each_existing_command_callback
    %w[scan_library_folder export_pack import_pack].each { |callback| assert_match(/ruby\(\"#{callback}\"\)/, js) }
    assert_match(/action === "settings".*?openSettings/m, js)
    assert_match(/onOverflowCommand/, js)
  end

  def test_model_save_sends_definition_guid_as_a_json_object
    assert_match(/modeltab_save_to_library[^\n]+definition_guid/, js)
    assert_match(/save_in_model_definition/, main)
    assert_match(/parse_payload\(payload\).*?data\['definition_guid'\]/m, main)
  end

  def test_settings_command_opens_the_library_settings_dialog_and_only_change_root_opens_the_folder_picker
    settings_start = main.index('def open_settings')
    change_root_start = main.index('def change_library_root')
    settings_method = main[settings_start, change_root_start - settings_start]
    change_root_method = main[change_root_start, main.index('def create_new_library_root') - change_root_start]

    assert_includes settings_method, 'open_library'
    assert_includes settings_method, 'ComponentLibrary.openSettings'
    refute_includes settings_method, 'choose_library_root'
    assert_includes change_root_method, 'choose_library_root'
    assert_match(/settings-change-root.*?ruby\("change_library_root"\)/m, js)
    assert_match(/legacy-change-root.*?ruby\("change_library_root"\)/m, js)
    assert_includes main, "add_action_callback('change_library_root')"
  end

  def test_reload_stays_in_extensions_menu_without_a_toolbar_icon
    command_setup = main[main.index('def setup_commands'), main.index('def build_command') - main.index('def setup_commands')]
    toolbar_setup = main[main.index('def setup_toolbar'), main.index('def close_live_plugin_sessions_before_reload') - main.index('def setup_toolbar')]
    icon_dir = File.join(ROOT, 'component_library_browser', 'icons')

    assert_includes command_setup, '@commands[:reload_plugin]'
    refute_match(/@commands\[:reload_plugin\].*?icon_prefix:/m, command_setup)
    assert_includes main, 'menu.add_item(@commands[:reload_plugin])'
    refute_includes toolbar_setup, '@toolbar.add_item(@commands[:reload_plugin])'
    refute File.exist?(File.join(icon_dir, 'reset_16.png'))
    refute File.exist?(File.join(icon_dir, 'reset_24.png'))
  end

  def test_update_check_routes_available_versions_to_a_compact_confirm_dialog
    assert_includes main, 'def show_update_dialog'
    assert_includes main, "dialog.add_action_callback('install_update')"
    assert_includes main, "dialog.add_action_callback('cancel_update')"
    assert_match(/current_version.*latest_version/m, main)
    cancel_callback = main[main.index("dialog.add_action_callback('cancel_update')"), main.index("dialog.add_action_callback('install_update')") - main.index("dialog.add_action_callback('cancel_update')")]
    assert_includes cancel_callback, 'dialog.close'
    refute_includes cancel_callback, 'download_and_apply_update'
    assert_match(/download_and_apply_update\(update: update, on_status:/m, main)
    assert_includes main, 'Обновление подготовлено. Требуется перезапуск SketchUp.'
  end
end
