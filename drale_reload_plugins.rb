# encoding: UTF-8
# drale_reload_plugins.rb
# Загрузчик плагина "Перезагрузка плагинов"

require 'sketchup.rb'
require 'extensions.rb'

module DraleTools
  module ReloadPlugins

    unless defined?(EXTENSION)
      EXTENSION = SketchupExtension.new(
        'Перезагрузка плагинов',
        File.join(File.dirname(__FILE__), 'drale_reload_plugins', 'main')
      )
      EXTENSION.description = 'Добавляет пункт меню "Перезагрузить все плагины" — ' \
                               'позволяет перезагружать плагины без перезапуска SketchUp.'
      EXTENSION.version     = '1.0.0'
      EXTENSION.creator     = 'Drale Tools'
      Sketchup.register_extension(EXTENSION, true)
    end

  end
end
