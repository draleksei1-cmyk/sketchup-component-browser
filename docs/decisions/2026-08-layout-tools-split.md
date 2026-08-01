# Layout tools: fixed public boundaries

## Decision

Expose two independent layout tools:

- `Tools::BrickLayoutTool` for brick/grid layouts;
- `Tools::WindowLayoutTool` for face-attached window layouts.

Each controller creates only its own public tool and retains its own palette,
callbacks, lifecycle and in-memory session namespace. `ArrayTool` remains the
shared legacy interaction implementation, not a menu command or a selectable
window engine. Its layout kind is fixed at construction; changing a payload's
legacy `mode` value cannot switch the running tool.

The only extracted common calculations are pure primitives:

- `LayoutGeometry` — grid offsets and brick row shifts;
- `WindowPlacement` — face-space and front-to-host window transforms.

Neither module reads SketchUp UI state, controller state, or a global mode.
All four tool/primitives files are included in the existing safe reload list.
The former Native Copy controller remains internal compatibility code only; it
uses the canonical window public tool and no `windows_native_copy` mode.

## SketchUp 2026 smoke matrix

| Tool | Manual check | Expected result |
| --- | --- | --- |
| Brick layout | Launch from Extensions and toolbar, choose a component, preview, apply, cancel. | One Brick command per surface; grouped grid keeps bond, rotation and spacing. |
| Window layout | Launch from Extensions and toolbar, pick a cutting window and a wall face, preview, apply, cancel. | One Window command per surface; preview and placed windows retain the canonical face orientation and cut/glue correctly. |
| Grid/Array compatibility | Reopen brick layout, alter spacing, reload plugin, reopen window layout. | Brick and window session values remain separate; reload keeps both commands and no Native Copy entry appears. |
