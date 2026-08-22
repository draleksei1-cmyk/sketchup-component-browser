require_relative 'placement'
require_relative 'insert_diagnostics'

module Drale
  module ComponentLibraryBrowser
    module Services
      module Replacer
        extend self

        # Заменяет выделенные Group/ComponentInstance на target_definition,
        # сохраняя transformation и контекст родительских entities.
        # Если у нового элемента задан паспорт размещения с точкой привязки —
        # совмещаются ТОЧКИ ПРИВЯЗКИ, а не оси: новое окно встаёт в тот же
        # проём даже при разных осях старой и новой модели.
        def replace_selection(target_definition, model = Sketchup.active_model, target_placement: nil)
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

              transformation = Placement.adjusted_transformation(entity, target_definition, target_placement)
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

              # Починка приклейки прорезных: если должен быть приклеен, но не приклеился.
              Placement.ensure_cutting_glue!(new_instance, target_definition)
              InsertDiagnostics.log_insert_result(target_definition, new_instance, method: :replace)
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
