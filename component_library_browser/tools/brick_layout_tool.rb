require_relative 'array_tool'

module Drale
  module ComponentLibraryBrowser
    module Tools
      class BrickLayoutTool < ArrayTool
        LAYOUT_KIND = 'brick'.freeze

        def initialize(controller)
          super(controller, LAYOUT_KIND)
          @params = { 'mode' => LAYOUT_KIND }
        end

        def update_params(params)
          fixed_params = params.is_a?(Hash) ? params.dup : {}
          fixed_params['mode'] = LAYOUT_KIND
          super(fixed_params)
        end
      end
    end
  end
end
