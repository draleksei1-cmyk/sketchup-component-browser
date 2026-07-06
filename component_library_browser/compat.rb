require_relative 'logger'

module Drale
  module ComponentLibraryBrowser
    module Compat
      extend self

      NEWER_MODEL_WARNING = 'Файл компонента создан в более новой версии SketchUp. Компонент вставлен, но некоторые данные могут быть потеряны.'.freeze

      def save_definition_to_file(definition, path, purpose:, library_path: nil)
        purpose = purpose.to_sym
        if purpose == :hash_temp
          unless definition.respond_to?(:save_copy)
            log_warn(
              'Дедупликация по content_hash недоступна: save_copy отсутствует',
              environment_snapshot(definition: definition, library_path: library_path).merge(
                'purpose' => purpose.to_s,
                'path' => path.to_s
              )
            )
            return false
          end

          definition.save_copy(path)
          return true
        end

        if definition.respond_to?(:save_copy)
          definition.save_copy(path)
        else
          definition.save_as(path)
        end
        true
      rescue StandardError => error
        log_error(
          'Ошибка сохранения определения в SKP',
          error,
          environment_snapshot(definition: definition, library_path: library_path).merge(
            'purpose' => purpose.to_s,
            'path' => path.to_s
          )
        )
        false
      end

      def load_definition_from_file(path, definitions: nil, notify_user: false, context: nil, library_path: nil)
        defs = definitions || Sketchup.active_model.definitions
        return defs.load(path)
      rescue RuntimeError => error
        unless newer_model_error?(error)
          log_error(
            'Ошибка загрузки определения из SKP',
            error,
            environment_snapshot(library_path: library_path).merge(
              'path' => path.to_s,
              'context' => context.to_s
            )
          )
          raise
        end

        definition = defs.load(path, allow_newer: true)
        log_warn(
          'SKP загружен через allow_newer',
          environment_snapshot(definition: definition, library_path: library_path).merge(
            'path' => path.to_s,
            'context' => context.to_s
          )
        )
        show_newer_model_warning_once if notify_user
        definition
      rescue StandardError => error
        log_error(
          'Ошибка загрузки определения из SKP',
          error,
          environment_snapshot(library_path: library_path).merge(
            'path' => path.to_s,
            'context' => context.to_s
          )
        )
        raise
      end

      def environment_snapshot(definition: nil, library_path: nil)
        {
          'sketchup_version' => sketchup_version_string,
          'ruby_version' => RUBY_VERSION.to_s,
          'save_copy_available' => save_copy_supported?(definition),
          'library_path' => library_path.to_s
        }
      end

      private

      def newer_model_error?(error)
        message = error.message.to_s.downcase
        message.include?('newer model version') || message.include?('allow_newer') || message.include?('более новой версии')
      end

      def show_newer_model_warning_once
        @newer_model_warning_shown ||= false
        return if @newer_model_warning_shown

        @newer_model_warning_shown = true
        UI.messagebox(NEWER_MODEL_WARNING)
      rescue StandardError
        # ignore UI errors
      end

      def save_copy_supported?(definition)
        return !!definition.respond_to?(:save_copy) if definition

        return Sketchup::ComponentDefinition.instance_methods.include?(:save_copy) if defined?(Sketchup::ComponentDefinition)

        false
      rescue StandardError
        false
      end

      def sketchup_version_string
        Sketchup.version.to_s
      rescue StandardError
        ''
      end

      def log_warn(message, data = nil)
        if defined?(Logger) && Logger.respond_to?(:warn)
          Logger.warn(message, data)
        else
          puts("[ComponentLibraryBrowser::Compat] WARN #{message} #{data}")
        end
      rescue StandardError
        # ignore logging errors
      end

      def log_error(message, error, data = nil)
        if defined?(Logger) && Logger.respond_to?(:error)
          Logger.error(message, error, data)
        else
          puts("[ComponentLibraryBrowser::Compat] ERROR #{message}: #{error.class} #{error.message}")
        end
      rescue StandardError
        # ignore logging errors
      end
    end
  end
end
