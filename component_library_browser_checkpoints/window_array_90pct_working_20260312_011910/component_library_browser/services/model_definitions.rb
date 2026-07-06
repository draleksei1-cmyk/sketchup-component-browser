module Drale
  module ComponentLibraryBrowser
    module Services
      module ModelDefinitions
        extend self

        # Возвращает массив используемых определений с количеством инстансов.
        def used_definitions(model = Sketchup.active_model)
          return [] unless model

          counts = Hash.new(0)
          visit_entities(model.entities, counts, {})

          counts.map do |definition, instances|
            {
              'definition' => definition,
              'definition_guid' => definition_identifier(definition),
              'name' => definition.name.to_s.strip.empty? ? 'Без имени' : definition.name.to_s,
              'instances_count' => instances
            }
          end.sort_by { |entry| entry['name'].downcase }
        end

        def select_all_instances(definition, model = Sketchup.active_model)
          return 0 unless model && definition

          targets = definition.instances.select(&:valid?)
          selection = model.selection
          selection.clear
          targets.each { |entity| selection.add(entity) if entity.valid? }
          targets.length
        end

        private

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

        def visit_entities(entities, counts, stack)
          entities.each do |entity|
            next unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)

            definition = entity.definition
            counts[definition] += 1

            key = definition_identifier(definition)
            next if stack[key]

            stack[key] = true
            visit_entities(definition.entities, counts, stack)
            stack.delete(key)
          end
        end

      end
    end
  end
end
