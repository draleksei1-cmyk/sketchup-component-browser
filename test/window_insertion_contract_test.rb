# frozen_string_literal: true

require 'minitest/autorun'

# A deliberately small Geom seam: production uses SketchUp's Geom classes while
# these tests exercise the placement maths without requiring SketchUp to launch.
module Geom
  class Vector3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x, @y, @z = x.to_f, y.to_f, z.to_f
    end

    def +(other)
      self.class.new(x + other.x, y + other.y, z + other.z)
    end

    def -(other)
      self.class.new(x - other.x, y - other.y, z - other.z)
    end
    def *(other)
      return self.class.new(x * other, y * other, z * other) if other.is_a?(Numeric)

      self.class.new(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
    end
    def dot(other)
      x * other.x + y * other.y + z * other.z
    end

    def length
      Math.sqrt(dot(self))
    end

    def normalize
      self * (1.0 / length)
    end

    def reverse
      self * -1.0
    end

    def transform(transformation)
      transformation.transform_vector(self)
    end
  end

  class Point3d < Vector3d
    def transform(transformation)
      transformation.transform_point(self)
    end

    def offset(vector, distance)
      self.class.new(x + vector.x * distance, y + vector.y * distance, z + vector.z * distance)
    end
  end

  class Transformation
    def self.axes(origin, x_axis, y_axis, z_axis)
      new(origin, x_axis, y_axis, z_axis)
    end

    def self.translation(vector)
      new(Point3d.new(vector.x, vector.y, vector.z), X_AXIS, Y_AXIS, Z_AXIS)
    end

    def initialize(origin = Point3d.new(0, 0, 0), x_axis = X_AXIS, y_axis = Y_AXIS, z_axis = Z_AXIS)
      @origin, @x_axis, @y_axis, @z_axis = origin, x_axis, y_axis, z_axis
    end

    attr_reader :x_axis, :y_axis, :z_axis
    alias xaxis x_axis
    alias yaxis y_axis
    alias zaxis z_axis

    def transform_point(point)
      Point3d.new(
        @origin.x + @x_axis.x * point.x + @y_axis.x * point.y + @z_axis.x * point.z,
        @origin.y + @x_axis.y * point.x + @y_axis.y * point.y + @z_axis.y * point.z,
        @origin.z + @x_axis.z * point.x + @y_axis.z * point.y + @z_axis.z * point.z
      )
    end

    def transform_vector(vector)
      Vector3d.new(
        @x_axis.x * vector.x + @y_axis.x * vector.y + @z_axis.x * vector.z,
        @x_axis.y * vector.x + @y_axis.y * vector.y + @z_axis.y * vector.z,
        @x_axis.z * vector.x + @y_axis.z * vector.y + @z_axis.z * vector.z
      )
    end

    def *(other)
      Transformation.axes(
        transform_point(ORIGIN.transform(other)),
        transform_vector(other.xaxis),
        transform_vector(other.yaxis),
        transform_vector(other.zaxis)
      )
    end

    def inverse
      # The fixtures use orthonormal frames, matching the window placement contract.
      ix = Vector3d.new(@x_axis.x, @y_axis.x, @z_axis.x)
      iy = Vector3d.new(@x_axis.y, @y_axis.y, @z_axis.y)
      iz = Vector3d.new(@x_axis.z, @y_axis.z, @z_axis.z)
      origin = Point3d.new(-@origin.dot(@x_axis), -@origin.dot(@y_axis), -@origin.dot(@z_axis))
      Transformation.axes(origin, ix, iy, iz)
    end
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0) unless defined?(ORIGIN)
X_AXIS = Geom::Vector3d.new(1, 0, 0) unless defined?(X_AXIS)
Y_AXIS = Geom::Vector3d.new(0, 1, 0) unless defined?(Y_AXIS)
Z_AXIS = Geom::Vector3d.new(0, 0, 1) unless defined?(Z_AXIS)

module Sketchup
  class InputPoint
  end

  class Face
    attr_reader :normal

    def initialize(normal)
      @normal = normal
    end

    def valid?
      true
    end
  end

  class ComponentInstance
    attr_reader :transformation, :glued_to

    def initialize(transformation, glued_to)
      @transformation = transformation
      @glued_to = glued_to
    end

    def valid?
      true
    end
  end
end

require_relative '../component_library_browser/tools/window_placement'
require_relative '../component_library_browser/tools/layout_geometry'
require_relative '../component_library_browser/tools/array_tool'
require_relative '../component_library_browser/tools/brick_layout_tool'
require_relative '../component_library_browser/tools/window_layout_tool'
require_relative '../component_library_browser/array/array_controller'
require_relative '../component_library_browser/array/win_array_controller'

class WindowInsertionContractTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_layout_geometry_is_pure_and_calculates_grid_offsets_without_a_mode
    geometry_source = File.read(
      File.join(ROOT, 'component_library_browser', 'tools', 'layout_geometry.rb'),
      encoding: 'UTF-8'
    )

    refute_match(/Sketchup|\bUI\b|@controller|@params|\bmode\b/, geometry_source)
    assert_equal 0.5, Drale::ComponentLibraryBrowser::Tools::LayoutGeometry.row_shift_factor(1, 'half')
    assert_in_delta 2.0 / 3.0, Drale::ComponentLibraryBrowser::Tools::LayoutGeometry.row_shift_factor(1, 'third'), 1.0e-12
    assert_equal [25.0, 7.0], Drale::ComponentLibraryBrowser::Tools::LayoutGeometry.grid_offsets(
      column: 2,
      row: 1,
      pitch_x: 10.0,
      pitch_y: 7.0,
      bond: 'half'
    )
  end

  def test_array_tool_uses_its_immutable_layout_kind_instead_of_params_mode
    source = File.read(
      File.join(ROOT, 'component_library_browser', 'tools', 'array_tool.rb'),
      encoding: 'UTF-8'
    )

    assert_includes source, 'def brick_layout?'
    assert_includes source, 'LayoutGeometry.grid_offsets'
    refute_includes source, "@params['mode']"
  end

  def test_public_layout_tools_keep_their_layout_kind_when_params_request_another_mode
    brick_tool = Drale::ComponentLibraryBrowser::Tools::BrickLayoutTool.new(Object.new)
    window_tool = Drale::ComponentLibraryBrowser::Tools::WindowLayoutTool.new(Object.new)

    brick_tool.update_params('mode' => 'windows')
    window_tool.update_params('mode' => 'brick')

    assert_equal 'brick', brick_tool.layout_kind
    assert_equal 'brick', brick_tool.instance_variable_get(:@params)['mode']
    assert_equal 'windows', window_tool.layout_kind
    assert_equal 'windows', window_tool.instance_variable_get(:@params)['mode']
  end

  def test_each_layout_controller_constructs_only_its_public_layout_tool
    brick_controller = File.read(File.join(ROOT, 'component_library_browser', 'array', 'array_controller.rb'), encoding: 'UTF-8')
    window_controller = File.read(File.join(ROOT, 'component_library_browser', 'array', 'win_array_controller.rb'), encoding: 'UTF-8')
    native_window_controller = File.read(File.join(ROOT, 'component_library_browser', 'array', 'win_array_native_controller.rb'), encoding: 'UTF-8')

    assert_includes brick_controller, 'Tools::BrickLayoutTool.new(self)'
    refute_includes brick_controller, 'Tools::WindowLayoutTool.new(self)'
    assert_includes window_controller, 'Tools::WindowLayoutTool.new(self)'
    refute_includes window_controller, 'Tools::BrickLayoutTool.new(self)'
    assert_includes native_window_controller, 'Tools::WindowLayoutTool.new(self)'
    refute_includes native_window_controller, 'Tools::BrickLayoutTool.new(self)'
    refute_includes [brick_controller, window_controller, native_window_controller].join("\n"), 'Tools::ArrayTool.new(self)'
  end

  def test_layout_sessions_use_separate_brick_and_window_namespaces
    brick_controller = File.read(File.join(ROOT, 'component_library_browser', 'array', 'array_controller.rb'), encoding: 'UTF-8')
    window_controller = File.read(File.join(ROOT, 'component_library_browser', 'array', 'win_array_controller.rb'), encoding: 'UTF-8')
    main = File.read(File.join(ROOT, 'component_library_browser', 'main.rb'), encoding: 'UTF-8')

    assert_includes brick_controller, 'read_brick_layout_session_params'
    assert_includes brick_controller, 'write_brick_layout_session_params'
    assert_includes window_controller, 'read_window_layout_session_params'
    assert_includes window_controller, 'write_window_layout_session_params'
    assert_match(/def read_brick_layout_session_params/, main)
    assert_match(/def read_window_layout_session_params/, main)
  end

  def test_main_exposes_one_menu_and_toolbar_command_for_each_public_layout_tool
    main = File.read(File.join(ROOT, 'component_library_browser', 'main.rb'), encoding: 'UTF-8')

    assert_equal 1, main.scan(/menu\.add_item\(@commands\[:array\]\)/).length
    assert_equal 1, main.scan(/menu\.add_item\(@commands\[:win_array\]\)/).length
    assert_equal 1, main.scan(/@toolbar\.add_item\(@commands\[:array\]\)/).length
    assert_equal 1, main.scan(/@toolbar\.add_item\(@commands\[:win_array\]\)/).length
  end

  def test_production_source_has_no_windows_native_copy_mode
    production_sources = Dir.glob(File.join(ROOT, 'component_library_browser', '**', '*.rb')).reject do |path|
      path.include?(File.join('component_library_browser', 'runtime_state'))
    end

    production_sources.each do |path|
      refute_includes File.read(path, encoding: 'UTF-8'), 'windows_native_copy', path
    end
  end

  def test_local_front_is_flipped_only_when_it_faces_away_from_host
    host_normal = Geom::Vector3d.new(0, 1, 0)
    backwards = Geom::Transformation.axes(ORIGIN, X_AXIS * 2.0, Z_AXIS * 3.0, host_normal.reverse * 0.5)

    placed = Drale::ComponentLibraryBrowser::Tools::WindowPlacement.for_host(backwards, host_normal)

    assert_operator Z_AXIS.transform(placed).normalize.dot(host_normal), :>, 0.999
    assert_in_delta WindowPlacementEpsilon, ORIGIN.transform(placed).dot(host_normal), 1.0e-12
    assert_in_delta 2.0, X_AXIS.transform(placed).length, 1.0e-12
    assert_in_delta 3.0, Y_AXIS.transform(placed).length, 1.0e-12
    assert_in_delta 0.5, Z_AXIS.transform(placed).length, 1.0e-12
  end

  def test_rotated_context_preserves_local_transform_when_converted_to_entities_space
    context = Geom::Transformation.axes(Geom::Point3d.new(12, -4, 3), Y_AXIS, X_AXIS.reverse, Z_AXIS)
    world = Geom::Transformation.axes(Geom::Point3d.new(13, -2, 3), Y_AXIS, X_AXIS.reverse, Z_AXIS)

    local = Drale::ComponentLibraryBrowser::Tools::WindowPlacement.local_transform(context, world)
    reconstructed = context * local

    assert_in_delta ORIGIN.transform(world).x, ORIGIN.transform(reconstructed).x, 1.0e-12
    assert_in_delta ORIGIN.transform(world).y, ORIGIN.transform(reconstructed).y, 1.0e-12
    assert_in_delta ORIGIN.transform(world).z, ORIGIN.transform(reconstructed).z, 1.0e-12
    assert_in_delta 1.0, Z_AXIS.transform(reconstructed).dot(Z_AXIS.transform(world)), 1.0e-12
  end

  def test_only_canonical_window_command_is_exposed
    main = File.read(File.join(ROOT, 'component_library_browser', 'main.rb'), encoding: 'UTF-8')

    assert_equal 1, main.scan(/menu_text: 'Раскладка окон\.\.\.'/).length
    assert_equal 1, main.scan(/icon_prefix: 'window'/).length
    assert_equal 1, main.scan(/menu\.add_item\(@commands\[:win_array\]\)/).length
    assert_equal 1, main.scan(/@toolbar\.add_item\(@commands\[:win_array\]\)/).length
    refute_match(/Раскладка окон \(Native Copy\)/, main)
    refute_match(/@commands\[:win_array_native\]/, main)
    refute_match(/start_win_array_native_layout/, main)
  end

  def test_canonical_window_pipeline_uses_native_component_insertion_without_camera_orientation
    controller = File.read(File.join(ROOT, 'component_library_browser', 'array', 'win_array_controller.rb'), encoding: 'UTF-8')
    tool = File.read(File.join(ROOT, 'component_library_browser', 'tools', 'array_tool.rb'), encoding: 'UTF-8')

    assert_match(/'mode'\s*=>\s*'windows'/, controller)
    assert_includes controller, 'entities.add_instance(@source_definition, local_tr)'
    assert_includes controller, 'valid_window_target?(face, entities, basis_tr)'
    refute_match(/ensure_normal_toward_camera/, tool)
    assert_includes tool, 'WindowPlacement.for_host'
  end

  def test_reload_includes_the_shared_window_placement_helper
    main = File.read(File.join(ROOT, 'component_library_browser', 'main.rb'), encoding: 'UTF-8')

    assert_match(/reload_paths\s*=\s*\[[\s\S]*'tools\/window_placement\.rb'/, main)
  end

  def test_source_instance_relative_frame_survives_a_rotated_context
    context = Geom::Transformation.axes(Geom::Point3d.new(10, -5, 2), Y_AXIS, X_AXIS.reverse, Z_AXIS)
    local_instance = Geom::Transformation.axes(Geom::Point3d.new(1, 2, 0), X_AXIS, Y_AXIS, Z_AXIS)
    world_instance = context * local_instance
    source = Sketchup::ComponentInstance.new(local_instance, Sketchup::Face.new(Z_AXIS))

    state = Drale::ComponentLibraryBrowser::ArrayLayout::WinArrayController.allocate.send(
      :build_source_window_prototype_state,
      source,
      world_instance
    )

    refute_nil state
    assert_instance_of Geom::Transformation, state[:relative_transform]
    assert_operator state[:source_face_z].dot(Z_AXIS), :>, 0.999

    target_frame = Geom::Transformation.axes(Geom::Point3d.new(-4, 7, 3), X_AXIS, Y_AXIS, Z_AXIS)
    tool = Drale::ComponentLibraryBrowser::Tools::ArrayTool.allocate
    tool.instance_variable_set(:@layout_kind, 'windows')
    tool.instance_variable_set(:@params, {})
    tool.instance_variable_set(:@source_window_prototype_state, state)
    placed = tool.send(:base_transform_from_source_window_prototype_state, target_frame, ORIGIN)

    assert_in_delta 1.0, X_AXIS.transform(placed).dot(Y_AXIS), 1.0e-12
    assert_in_delta(-1.0, Y_AXIS.transform(placed).dot(X_AXIS), 1.0e-12)
    assert_in_delta 1.0, Z_AXIS.transform(placed).dot(Z_AXIS), 1.0e-12
  end

  def test_glue_failure_does_not_erase_and_retry_with_an_unconditional_flip
    controller = File.read(File.join(ROOT, 'component_library_browser', 'array', 'win_array_controller.rb'), encoding: 'UTF-8')

    refute_match(/flip_world_transform/, controller)
    refute_match(/instance\.erase!/, controller)
  end

  def test_legacy_palette_session_round_trips_into_canonical_steps_without_data_loss
    controller = Drale::ComponentLibraryBrowser::ArrayLayout::WinArrayController.allocate
    legacy = {
      'count_x' => 4,
      'count_y' => 2,
      'axis_spacing_mm' => 3300.0,
      'floor_height_mm' => 3000.0
    }

    canonical = controller.send(:normalize_params, legacy)
    persisted = controller.send(:session_params_for_storage, canonical)

    assert_equal 4, canonical['count_x']
    assert_equal 2, canonical['count_y']
    assert_equal 3300.0, canonical['axis_spacing_mm']
    assert_equal 3000.0, canonical['floor_height_mm']
    assert_equal 3300.0, canonical['step_x_mm']
    assert_equal 3000.0, canonical['step_y_mm']
    assert_equal legacy, persisted
  end

  def test_session_accessors_are_used_by_the_canonical_controller
    controller = File.read(File.join(ROOT, 'component_library_browser', 'array', 'win_array_controller.rb'), encoding: 'UTF-8')

    assert_includes controller, '@host.read_win_array_session_params'
    assert_includes controller, '@host.write_win_array_session_params'

    host = Object.new
    saved = { 'count_x' => 3, 'count_y' => 5, 'axis_spacing_mm' => 1200.0, 'floor_height_mm' => 2800.0 }
    written = nil
    host.define_singleton_method(:read_win_array_session_params) { saved.dup }
    host.define_singleton_method(:write_win_array_session_params) { |params| written = params }

    instance = Drale::ComponentLibraryBrowser::ArrayLayout::WinArrayController.new(host)
    params = instance.instance_variable_get(:@params)
    assert_equal 1200.0, params['step_x_mm']
    assert_equal 2800.0, params['step_y_mm']

    instance.send(:persist_session_params)
    assert_equal saved, written
  end

  def test_manual_legacy_pitch_survives_open_choose_source_apply_flow
    controller = Drale::ComponentLibraryBrowser::ArrayLayout::WinArrayController.allocate
    manual = controller.send(
      :normalize_params,
      'count_x' => 2,
      'count_y' => 1,
      'axis_spacing_mm' => 3300.0,
      'floor_height_mm' => 3000.0,
      'auto_step' => false
    )
    controller.instance_variable_set(:@params, manual)

    controller.send(:apply_source_step_suggestions, 1500.0, 1200.0)
    applied = controller.instance_variable_get(:@params)

    assert_equal 3300.0, applied['step_x_mm']
    assert_equal 3000.0, applied['step_y_mm']
    assert_equal 3300.0, applied['axis_spacing_mm']
    assert_equal 3000.0, applied['floor_height_mm']
    assert_equal 1500.0, applied['suggested_step_x_mm']
    assert_equal 1200.0, applied['suggested_step_y_mm']
  end
end

WindowPlacementEpsilon = Drale::ComponentLibraryBrowser::Tools::WindowPlacement::SURFACE_EPSILON
