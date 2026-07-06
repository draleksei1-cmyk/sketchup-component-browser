# encoding: UTF-8
# drale_reload_plugins/main.rb
# Основная логика плагина перезагрузки

module DraleTools
  module ReloadPlugins

    # Перезагружает все .rb-файлы плагинов из папки Plugins.
    # Файлы, защищённые guard-блоком file_loaded?, получат обновлённый
    # код методов, но не создадут дублирующих пунктов меню / тулбаров.
    def self.reload_all_plugins
      plugins_dir = Sketchup.find_support_file('Plugins')
      unless plugins_dir
        UI.messagebox('Не удалось найти папку Plugins.')
        return
      end

      # Нормализуем разделители путей для кросс-платформенного сравнения
      plugins_norm = plugins_dir.gsub('\\', '/')

      # Путь к нашему собственному файлу — его не перезагружаем
      this_loader = File.expand_path(
        File.join(File.dirname(__FILE__), '..', 'drale_reload_plugins.rb')
      ).gsub('\\', '/')
      this_main   = File.expand_path(__FILE__).gsub('\\', '/')

      reloaded = []
      errors   = []

      # Выбираем только .rb-файлы из папки Plugins
      candidates = $LOADED_FEATURES.select { |f|
        fn = f.gsub('\\', '/')
        fn.start_with?(plugins_norm) &&
          fn.end_with?('.rb') &&
          fn != this_loader &&
          fn != this_main
      }

      candidates.each do |feature|
        begin
          load feature
          rel = feature.gsub('\\', '/').sub(plugins_norm + '/', '')
          reloaded << rel
        rescue => e
          errors << "#{File.basename(feature)}: #{e.message}"
        end
      end

      # Формируем отчёт
      lines = ["Перезагружено файлов: #{reloaded.length}"]

      unless errors.empty?
        lines << ''
        lines << "Ошибки (#{errors.length}):"
        lines.concat(errors.first(8))
        lines << "...и ещё #{errors.length - 8}" if errors.length > 8
      end

      UI.messagebox(lines.join("\n"))
    end

    # Добавляем пункт меню один раз
    unless file_loaded?(__FILE__)
      menu = UI.menu('Plugins')
      menu.add_separator
      menu.add_item('Перезагрузить все плагины') {
        DraleTools::ReloadPlugins.reload_all_plugins
      }
      file_loaded(__FILE__)
    end

  end
end
