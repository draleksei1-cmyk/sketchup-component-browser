# frozen_string_literal: true

module Drale
  module ComponentLibraryBrowser
    module Tools
      module LayoutGeometry
        module_function

        def row_shift_factor(row, bond)
          case bond
          when 'half'
            row.to_i.odd? ? 0.5 : 0.0
          when 'third'
            [1.0 / 3.0, 2.0 / 3.0, 0.0][row.to_i % 3]
          else
            0.0
          end
        end

        def grid_offsets(column:, row:, pitch_x:, pitch_y:, bond: nil)
          shift = row_shift_factor(row, bond)
          [(column.to_f + shift) * pitch_x.to_f, row.to_f * pitch_y.to_f]
        end
      end
    end
  end
end
