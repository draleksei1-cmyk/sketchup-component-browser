module Drale
  module ComponentLibraryBrowser
    module Services
      module Metadata
        extend self

        def quick_metadata(definition, skp_full_path = nil)
          return default_metadata unless definition

          bounds = definition.bounds
          file_size = (skp_full_path && File.file?(skp_full_path)) ? File.size(skp_full_path) : nil

          {
            'file_size_bytes' => file_size,
            'bbox_xyz' => [bounds.width.to_f, bounds.depth.to_f, bounds.height.to_f],
            'faces_count' => nil,
            'edges_count' => nil,
            'materials_count' => materials_count_for_definition(definition)
          }
        rescue StandardError
          default_metadata
        end

        def deep_metadata(definition)
          return default_metadata unless definition

          counts = {
            'faces_count' => 0,
            'edges_count' => 0,
            'materials' => {}
          }

          walk_entities(definition.entities, counts, {})
          {
            'faces_count' => counts['faces_count'],
            'edges_count' => counts['edges_count'],
            'materials_count' => counts['materials'].keys.length
          }
        rescue StandardError
          {
            'faces_count' => nil,
            'edges_count' => nil,
            'materials_count' => nil
          }
        end

        def default_metadata
          {
            'file_size_bytes' => nil,
            'bbox_xyz' => nil,
            'faces_count' => nil,
            'edges_count' => nil,
            'materials_count' => nil
          }
        end

        private

        def materials_count_for_definition(definition)
          materials = {}
          walk_entities(definition.entities, { 'faces_count' => 0, 'edges_count' => 0, 'materials' => materials }, {})
          materials.keys.length
        end

        def walk_entities(entities, counts, stack)
          entities.each do |entity|
            counts['faces_count'] += 1 if entity.is_a?(Sketchup::Face)
            counts['edges_count'] += 1 if entity.is_a?(Sketchup::Edge)

            if entity.respond_to?(:material) && entity.material
              counts['materials'][entity.material.display_name] = true
            end
            if entity.respond_to?(:back_material) && entity.back_material
              counts['materials'][entity.back_material.display_name] = true
            end

            next unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)

            definition = entity.definition
            key = definition.guid
            next if stack[key]

            stack[key] = true
            walk_entities(definition.entities, counts, stack)
            stack.delete(key)
          end
        end
      end
    end
  end
end
