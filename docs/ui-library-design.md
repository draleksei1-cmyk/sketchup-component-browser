# Library UI design

The library is a restrained three-part workspace: a fixed 200px navigation rail, a flexible component grid, and a 360px details drawer. The drawer is closed initially. At widths above 1440px it occupies its own column; at 1440px and below it overlays the grid. At 1040px the rail becomes a compact top navigation.

Cards deliberately show only preview, name, category, and at most two tags. Selecting a card opens the drawer; double-clicking preserves the direct insert action. Favorite and delete are not card controls. Delete remains available only through the card context menu, which calls the existing Ruby callback and therefore retains its native confirmation.

The card-size switch keeps the default medium density compact: `S` uses a 144px minimum card width, `M` uses 176px, and `L` uses 260px. The category action and the bottom-left settings action use the same 32px icon-button geometry with an 18px canonical SVG.

## Action inventory

| Existing action / callback | New location |
| --- | --- |
| `ready`, `refresh_selection_state`, `select_item` | application bootstrap and card selection |
| `get_state`, `js_error` | SketchUp bridge lifecycle / error transport (no visible control) |
| `refresh_index_only` | toolbar refresh button |
| `scan_library_folder` | toolbar overflow: deep scan |
| `refresh_in_model` | “В модели” navigation scope |
| `modeltab_save_to_library`, `save_in_model_definition` | model-item action retained by the SketchUp model workflow |
| `replace_selection_model`, `replace_with_model_definition` | model-item replacement workflow |
| `modeltab_select_all`, `select_all_in_model` | model-item selection workflow |
| `insert_item`, `array_pick_from_library` | drawer main button / card double click |
| `start_brush` | Drawer → Placement |
| `replace_selection`, `replace_library_item_from_selection` | Drawer → Replace |
| `toggle_favorite` | drawer header star |
| `update_item_fields` | Drawer → Edit fields on blur/change |
| `set_insert_option` | Drawer → Placement options |
| `regenerate_thumbnail`, `show_in_folder`, `open_folder` | Drawer → Maintenance |
| `delete_item` | card context menu only |
| `category_add` | rail Categories header |
| `category_rename`, `category_delete`, `regenerate_previews_category` | selected-category contextual actions (native menu/legacy command) |
| `toggle_pinned_category` | category contextual action |
| `save_selected` | rail footer |
| `set_heavy_threshold` | Settings modal |
| `set_insert_options` | legacy batch placement-setting transport; per-field UI uses `set_insert_option` |
| `refresh_item_metadata` | metadata refresh after file operations |
| `scan_library`, `regenerate_previews_all`, `open_settings` | Settings modal |
| `export_pack`, `import_pack` | toolbar overflow |
| `copy_path` | card context menu utility action |
| `js_error` | existing SketchUp error forwarding remains in Ruby/UI integration |

The legacy callback aliases remain handled by Ruby and the UI calls the preferred names (`start_brush`, `replace_selection`, `regenerate_thumbnail`, `open_folder`, `show_in_folder`, `update_item_fields`). Array source-pick state stays visible as an in-grid banner and preserves the double-click `array_pick_from_library` route.

## Interaction rules

Popup menus close on Escape and outside click, then return focus to their invoking control or card. All keyboard-focusable controls have a visible focus ring. Context menus can be opened with the Context Menu key or Shift+F10. No action button uses a Unicode glyph as its only visible control; SVG icons always have accessible labels supplied by their buttons.
