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

require_relative '../component_library_browser/tools/window_placement'

class WindowInsertionContractTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

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
end

WindowPlacementEpsilon = Drale::ComponentLibraryBrowser::Tools::WindowPlacement::SURFACE_EPSILON
