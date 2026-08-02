# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class << self
    attr_accessor :status_text
  end

  class EntitiesObserver; end
  class SelectionObserver; end
end

module UI
  class HtmlDialog
    STYLE_DIALOG = 0
  end
end

def file_loaded?(_path)
  true
end

module Drale
  module ComponentLibraryBrowser
    EXTENSION_VERSION = File.read(File.expand_path('../component_library_browser/VERSION', __dir__), encoding: 'UTF-8').strip
  end
end

require_relative '../component_library_browser/main'

class UpdateInstallFlowTest < Minitest::Test
  Updater = Drale::ComponentLibraryBrowser::Updater
  Plugin = Drale::ComponentLibraryBrowser

  class FakeUpdateDialog
    attr_reader :scripts

    def initialize
      @scripts = []
      @closed = false
    end

    def execute_script(script)
      @scripts << script
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  def test_successful_install_never_reloads_an_active_locked_plugin
    dialog = FakeUpdateDialog.new
    reload_called = false
    observed_package_lock = nil
    original_download = Updater.method(:download_and_apply_update)
    original_reload = Updater.method(:reload_plugin!)
    Updater.define_singleton_method(:download_and_apply_update) do |update:, on_status:|
      on_status.call('Установка обновления…')
      observed_package_lock = update.fetch('package_lock')
      { 'success' => true, 'version' => '0.3.0' }
    end
    Updater.define_singleton_method(:reload_plugin!) { reload_called = true }

    Plugin.install_update_from_dialog(dialog, { 'package_lock' => 'locked-active-package' })

    assert_equal 'locked-active-package', observed_package_lock
    assert dialog.closed?, 'successful installation must terminate the update dialog'
    assert_includes dialog.scripts.last, 'Обновление установлено. Перезапустите SketchUp.'
    refute reload_called, 'an installed update must wait for SketchUp restart instead of reloading loaded files'
  ensure
    Updater.define_singleton_method(:download_and_apply_update, original_download) if original_download
    Updater.define_singleton_method(:reload_plugin!, original_reload) if original_reload
  end
end
