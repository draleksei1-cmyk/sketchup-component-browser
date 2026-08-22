# frozen_string_literal: true

module Drale
  module ComponentLibraryBrowser
    module Services
      # Диагностика вставок компонентов: логирует каждую вставку
      # (способ вставки, прорезание отверстий, приклейку к поверхности).
      # Совместимо с Ruby 2.7 (без Hash#except, pattern matching и Data).
      module InsertDiagnostics
        extend self

        # Допустимые способы вставки (для контроля в логе)
        VALID_METHODS = %i[button brush array window_tool replace].freeze

        # Логирует начало вставки компонента.
        # Вызывается ПЕРЕД model.place_component.
        #
        # @param item_id  [String] идентификатор элемента библиотеки
        # @param skp_path [String] полный путь к SKP-файлу
        # @param method   [Symbol] способ вставки: :button, :brush, :array, :window_tool
        def log_insert_start(item_id:, skp_path:, method:)
          Logger.info(
            'Вставка: начало',
            'item_id' => item_id.to_s,
            'skp_path' => skp_path.to_s,
            'method' => normalize_method(method)
          )
        rescue StandardError => e
          Logger.error('Вставка: ошибка логирования начала', e)
          nil
        end

        # Логирует результат вставки: прорезание отверстий (cuts_opening),
        # приклейку (glued_to), версии SketchUp и Ruby.
        # Безопасно при instance == nil (place_component не всегда возвращает экземпляр).
        #
        # @param definition [Sketchup::ComponentDefinition, nil]
        # @param instance   [Sketchup::ComponentInstance, nil] может отсутствовать
        # @param method     [Symbol] способ вставки
        def log_insert_result(definition, instance, method:)
          Logger.info(
            'Вставка: результат',
            {
              'method' => normalize_method(method),
              'definition' => definition_summary(definition),
              'instance' => instance_summary(instance),
              'cuts_opening' => cuts_opening?(definition),
              'glued_to' => glued_target(instance),
              'sketchup_version' => sketchup_version,
              'ruby_version' => RUBY_VERSION
            }
          )
        rescue StandardError => e
          Logger.error('Вставка: ошибка логирования результата', e)
          nil
        end

        private

        # Приводит способ вставки к строке, помечая неизвестные значения
        def normalize_method(method)
          m = method.to_s.empty? ? 'unknown' : method.to_sym
          VALID_METHODS.include?(m) ? m.to_s : "unknown(#{method})"
        rescue StandardError
          'unknown'
        end

        # Краткое описание определения компонента (nil-safe)
        def definition_summary(definition)
          return nil unless definition.respond_to?(:name)

          { 'name' => definition.name.to_s }
        rescue StandardError
          nil
        end

        # Краткое описание экземпляра (nil-safe: place_component может не вернуть instance)
        def instance_summary(instance)
          return nil if instance.nil?
          return { 'valid' => false } unless instance.respond_to?(:valid?) && instance.valid?

          summary = { 'valid' => true }
          summary['entity_id'] = instance.entityID if instance.respond_to?(:entityID)
          summary
        rescue StandardError
          { 'summary_error' => true }
        end

        # Прорезает ли компонент отверстия (берём из definition.behavior, nil-safe)
        def cuts_opening?(definition)
          return nil unless definition.respond_to?(:behavior)

          behavior = definition.behavior
          return nil unless behavior && behavior.respond_to?(:cuts_opening?)

          behavior.cuts_opening?
        rescue StandardError
          nil
        end

        # К чему приклеен экземпляр (nil-safe)
        def glued_target(instance)
          return nil if instance.nil?
          return nil unless instance.respond_to?(:glued_to)

          target = instance.glued_to
          target.nil? ? nil : target.to_s
        rescue StandardError
          nil
        end

        # Версия SketchUp (nil-safe вне среды SketchUp)
        def sketchup_version
          defined?(Sketchup) && Sketchup.respond_to?(:version) ? Sketchup.version.to_s : nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
