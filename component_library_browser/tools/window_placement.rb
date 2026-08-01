# frozen_string_literal: true

module Drale
  module ComponentLibraryBrowser
    module Tools
      # Geometry-only part of the window insertion contract. It deliberately
      # knows nothing about the camera or UI: a window is oriented solely from
      # its definition axes and the target face's world-space normal.
      module WindowPlacement
        SURFACE_EPSILON = 1.0e-6

        module_function

        def local_transform(context_transform, world_transform)
          context_transform.inverse * world_transform
        end

        def face_normal_in_world(face_normal, entity_world_transform, entity_local_transform)
          context_transform = entity_world_transform * entity_local_transform.inverse
          normalize(face_normal.transform(context_transform))
        rescue StandardError
          nil
        end

        # Keeps local +Z (the component's gluing/cutting front) on the same
        # side as the host face normal. A 180 degree turn is only applied when
        # that concrete front/back test says it is necessary.
        def for_host(transform, host_normal, epsilon: SURFACE_EPSILON)
          normal = normalize(host_normal)
          raise ArgumentError, 'Target face normal is invalid.' unless normal

          origin = ORIGIN.transform(transform)
          x_axis = X_AXIS.transform(transform)
          y_axis = Y_AXIS.transform(transform)
          z_axis = Z_AXIS.transform(transform)
          front = normalize(z_axis)
          raise ArgumentError, 'Component transform is invalid.' unless x_axis && y_axis && front

          if front.dot(normal) < 0.0
            x_axis = x_axis.reverse
            z_axis = z_axis.reverse
          end

          Geom::Transformation.axes(origin.offset(normal, epsilon.to_f), x_axis, y_axis, z_axis)
        end

        def normalize(vector)
          return nil unless vector

          result = Geom::Vector3d.new(vector.x, vector.y, vector.z)
          return nil unless result.length > 1.0e-9

          result.normalize
        rescue StandardError
          nil
        end
      end
    end
  end
end
