# Icon export

Source icons live in `component_library_browser/icons` as monochrome 24×24 SVGs. They use `fill="none"`, `currentColor`, 1.75px strokes, and rounded caps/joins. HTML dialogs use these SVG files directly.

Toolbar raster files are only made for the `icon_prefix` values exposed in `component_library_browser/main.rb`: `open`, `save`, `brick`, `window`, `settings`, and `reset`. Other SVGs intentionally have no PNG pairs.

## Export

On Windows run:

```powershell
./scripts/export_toolbar_icons.ps1
```

The script uses the locally installed Chrome headless renderer at `C:\Program Files\Google\Chrome\Application\chrome.exe`; pass `-ChromePath` to choose another Chrome/Chromium executable. It reads the Ruby toolbar mappings, renders each mapped SVG at 16 and 24 pixels, and rejects invalid or incorrectly sized PNG files. The output is reproducible and must not be hand-edited.

## Release checklist

- Run the export script after changing a toolbar SVG.
- Run `ruby test/ui/static_ui_contract_test.rb`.
- Confirm every mapped prefix has both exact-size PNGs and no unmapped PNG pairs exist.
- Inspect the SVG icon sheet at 16px on light and dark backgrounds.
