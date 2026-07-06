require 'sketchup.rb'
require 'extensions.rb'

module Drale
  module ComponentLibraryBrowser
    EXTENSION_NAME = "\u0411\u0438\u0431\u043b\u0438\u043e\u0442\u0435\u043a\u0430 \u043a\u043e\u043c\u043f\u043e\u043d\u0435\u043d\u0442\u043e\u0432".freeze

    unless const_defined?(:EXTENSION)
      loader_path = File.join('component_library_browser', 'main')
      extension = SketchupExtension.new(EXTENSION_NAME, loader_path)
      extension.description = 'Models library and organizer for SketchUp.'
      extension.version = '0.1'
      extension.creator = 'Aleksei Serov'
      self::EXTENSION = extension
    end
  end
end

unless file_loaded?(__FILE__)
  Sketchup.register_extension(Drale::ComponentLibraryBrowser::EXTENSION, true)
  file_loaded(__FILE__)
end
