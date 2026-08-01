# frozen_string_literal: true

require 'minitest/autorun'

# A small SketchUp/UI seam that makes the native component placement lifecycle
# testable without launching SketchUp.
module Sketchup
  class EntitiesObserver; end
  class SelectionObserver; end
  class ComponentInstance; end
  class Group; end

  class << self
    attr_accessor :active_model, :status_text
  end
end

module UI
  class HtmlDialog
    STYLE_DIALOG = :dialog
  end

  class << self
    attr_reader :stopped_timers

    def stop_timer(timer)
      (@stopped_timers ||= []) << timer
    end
  end
end

def file_loaded?(_path)
  true
end

def file_loaded(_path)
  true
end

require_relative '../component_library_browser/main'

class NativeBrushEscapeTest < Minitest::Test
  Host = Drale::ComponentLibraryBrowser

  class FakeEntities
    attr_reader :removed

    def remove_observer(observer)
      @removed = observer
    end
  end

  class FakeTools
    attr_accessor :active_tool_name

    def initialize(name)
      @active_tool_name = name
    end
  end

  class FakeModel
    attr_reader :tools, :selected_tools

    def initialize(active_tool_name: 'Component')
      @tools = FakeTools.new(active_tool_name)
      @selected_tools = []
    end

    def select_tool(tool)
      @selected_tools << tool
    end
  end

  class FakeDialog
    attr_reader :scripts

    def initialize
      @scripts = []
    end

    def execute_script(script)
      @scripts << script
    end
  end

  def setup
    Sketchup.status_text = 'Многократная вставка: клик для установки.'
    Sketchup.active_model = FakeModel.new
    UI.instance_variable_set(:@stopped_timers, [])
    @entities = FakeEntities.new
    @dialog = FakeDialog.new
    Host.instance_variable_set(:@dialog, @dialog)
    Host.instance_variable_set(:@native_brush_entities_observer, Object.new)
    Host.instance_variable_set(:@native_brush_observed_entities, @entities)
    Host.instance_variable_set(:@native_brush_restart_timer, :restart_timer)
    Host.instance_variable_set(:@native_brush_watchdog_timer, :watchdog_timer)
    Host.instance_variable_set(:@native_brush_loop, active_loop)
  end

  def teardown
    %i[@dialog @native_brush_entities_observer @native_brush_observed_entities @native_brush_restart_timer @native_brush_watchdog_timer @native_brush_loop].each do |name|
      Host.remove_instance_variable(name) if Host.instance_variable_defined?(name)
    end
    Sketchup.active_model = nil
  end

  def test_dialog_escape_uses_the_canonical_cancel_path_and_clears_active_state
    assert Host.cancel_native_brush

    assert_nil Host.instance_variable_get(:@native_brush_loop)
    assert_equal [nil], Sketchup.active_model.selected_tools
    assert_equal '', Sketchup.status_text
    assert_same Host.instance_variable_get(:@native_brush_entities_observer), @entities.removed
    assert_equal %i[restart_timer watchdog_timer], UI.stopped_timers
    assert_includes @dialog.scripts.last, 'setStatus("")'
  end

  def test_canvas_escape_stops_the_waiting_native_cycle_as_soon_as_component_tool_is_gone
    Sketchup.active_model.tools.active_tool_name = 'Select Tool'
    Host.send(:monitor_native_brush_loop)

    assert_nil Host.instance_variable_get(:@native_brush_loop)
    assert_equal '', Sketchup.status_text
  end

  private

  def active_loop
    {
      definition: Object.new,
      definition_id: 'definition-1',
      item_id: 'asset-1',
      continuous: true,
      generation: 1,
      waiting_for_insert: true,
      used: false,
      placed_count: 0,
      last_place_at: Time.now.to_f,
      last_insert_at: 0.0
    }
  end
end
