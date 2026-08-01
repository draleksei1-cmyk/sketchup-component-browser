# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../component_library_browser/services/runtime_manifest'

class RuntimeManifestTest < Minitest::Test
  Manifest = Drale::ComponentLibraryBrowser::RuntimeManifest

  def test_manifest_contains_every_runtime_file_needed_after_layout_split
    required = %w[
      services/updater.rb
      tools/layout_geometry.rb
      tools/window_placement.rb
      tools/brick_layout_tool.rb
      tools/window_layout_tool.rb
      array/array_controller.rb
      array/win_array_controller.rb
      main.rb
    ]

    required.each { |path| assert_includes Manifest::RELOAD_PATHS, path }
  end

  def test_reload_paths_are_scoped_to_the_extension_directory
    root = File.expand_path('../component_library_browser', __dir__)
    paths = Manifest.absolute_reload_paths(root)

    assert paths.all? { |path| Manifest.path_within?(root, path) }
    assert_raises(ArgumentError) { Manifest.path_within?(root, File.join(File.dirname(root), 'outside.rb'), raise_on_failure: true) }
  end

  def test_main_uses_the_scoped_reload_manifest
    main = File.read(File.expand_path('../component_library_browser/main.rb', __dir__), encoding: 'UTF-8')

    assert_includes main, "require_relative 'services/runtime_manifest'"
    assert_includes main, 'RuntimeManifest.absolute_reload_paths(plugin_dir)'
  end

  def test_boot_reports_restart_required_after_a_pending_update_swap
    main = File.read(File.expand_path('../component_library_browser/main.rb', __dir__), encoding: 'UTF-8')
    boot = main[main.index('def boot!'), 900]

    assert_includes boot, "pending_update['success']"
    assert_includes boot, 'Sketchup.status_text ='
    assert_includes boot, 'Restart SketchUp to load the new code.'
    refute_includes boot, 'reload_plugin!'
  end
end
