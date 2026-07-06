module Drale
  module ComponentLibraryBrowser
    module Services
      module Replacer
        extend self

        # Заменяет выделенные Group/ComponentInstance на target_definition,
        # сохраняя transformation и контекст родительских entities.
        def replace_selection(target_definition, model = Sketchup.active_model)
          raise ArgumentError, 'Целевое определение не задано.' unless target_definition
          raise ArgumentError, 'Модель не найдена.' unless model

          selection = model.selection.to_a
          raise ArgumentError, 'Ничего не выделено.' if selection.empty?

          replaced = 0
          skipped = 0

          model.start_operation('Замена компонентов', true)
          begin
            selection.each do |entity|
              unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
                skipped += 1
                next
              end

              next unless entity.valid?

              parent = entity.parent
              next unless parent.respond_to?(:entities)

              transformation = entity.transformation
              glued_target = entity.respond_to?(:glued_to) ? entity.glued_to : nil
              entity.erase!
              new_instance = parent.entities.add_instance(target_definition, transformation)

              if glued_target && new_instance.respond_to?(:glued_to=)
                begin
                  new_instance.glued_to = glued_target
                rescue StandardError
                  # target definition may not support gluing/cutting
                end
              end
              replaced += 1
            end
            model.commit_operation
          rescue StandardError
            model.abort_operation
            raise
          end

          { 'replaced' => replaced, 'skipped' => skipped }
        end
      end
    end
  end
end
