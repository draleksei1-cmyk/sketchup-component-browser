require 'sketchup.rb'
require 'extensions.rb'

module Drale
  module ComponentLibraryBrowser
    EXTENSION_NAME = 'Component Library Browser'.freeze
    EXTENSION_VERSION = '0.1'.freeze
    EXTENSION_CREATOR = 'ALeksei Serov'.freeze
    EXTENSION_COPYRIGHT = 'Copyright (c) ALeksei Serov'.freeze
    EXTENSION_DESCRIPTION = 'Local component and model library organizer for SketchUp.'.freeze

    unless const_defined?(:EXTENSION)
      extension = SketchupExtension.new(EXTENSION_NAME, 'component_library_browser/main')
      extension.version = EXTENSION_VERSION
      extension.creator = EXTENSION_CREATOR
      extension.copyright = EXTENSION_COPYRIGHT
      extension.description = EXTENSION_DESCRIPTION
      self::EXTENSION = extension
    end
  end
end

unless file_loaded?(__FILE__)
  Sketchup.register_extension(Drale::ComponentLibraryBrowser::EXTENSION, true)
  file_loaded(__FILE__)
end
