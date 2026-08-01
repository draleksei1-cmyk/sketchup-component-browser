# frozen_string_literal: true

module Drale
  module ComponentLibraryBrowser
    # Explicit runtime code list. Reloading is deliberately limited to this
    # extension directory; it cannot reload unrelated files from Plugins.
    module RuntimeManifest
      EXTENSION_ROOT = File.expand_path('..', __dir__).freeze
      RELOAD_PATHS = %w[
        fs.rb
        storage.rb
        logger.rb
        compat.rb
        services/model_definitions.rb
        services/replacer.rb
        services/metadata.rb
        services/preview_regenerator.rb
        services/pack_transfer.rb
        services/updater.rb
        tools/pick_source_tool.rb
        tools/layout_geometry.rb
        tools/array_tool.rb
        tools/window_placement.rb
        tools/brick_layout_tool.rb
        tools/window_layout_tool.rb
        array/array_controller.rb
        array/win_array_controller.rb
        main.rb
      ].freeze

      module_function

      def absolute_reload_paths(root = EXTENSION_ROOT)
        root = File.expand_path(root)
        RELOAD_PATHS.map do |relative_path|
          path = File.expand_path(relative_path, root)
          path_within?(root, path, raise_on_failure: true)
          path
        end
      end

      def path_within?(root, path, raise_on_failure: false)
        root = File.expand_path(root)
        path = File.expand_path(path)
        within = path == root || path.start_with?(root + File::SEPARATOR)
        raise ArgumentError, "Reload path outside extension root: #{path}" if raise_on_failure && !within

        within
      end
    end
  end
end
