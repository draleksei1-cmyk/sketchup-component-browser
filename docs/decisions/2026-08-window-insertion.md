# Window insertion: one canonical pipeline

## Decision

Expose one public command, **«Раскладка окон»**. It uses the former native-copy
face-frame algorithm inside `WinArrayController`. The experimental **Native
Copy** command is removed from the Extensions menu, toolbar, reload list, and
library-pick dispatch. Existing saved window settings remain compatible because
their `count_*`, spacing, seam, and `mode: windows` values are unchanged. The
shared placement helper is included in the explicit safe reload list, so a
plugin reload cannot retain stale placement geometry.

## Placement contract

- Build the target frame from the face's world origin, normal, and stable
  tangent/up axes; do not use the camera direction.
- Preserve a picked instance's transform relative to its source face frame,
  including rotated group/component contexts.
- Test the transformed component local +Z against the host normal. Rotate 180°
  only when it faces away, then use a deterministic `1e-6` model-unit offset.
- Insert the original definition through `Entities#add_instance` in the target
  entities context and set `glued_to`; do not recreate its faces/materials or
  perform host booleans/erasures. If an opening component cannot glue, abort
  the operation; do not erase and retry it with an arbitrary second flip.

## SketchUp 2026 manual acceptance

| Fixture | Check |
| --- | --- |
| Front and back wall faces | Component front and cutting opening match ordinary SketchUp component placement on each side. |
| Reversed wall face normal | Placement follows the actual host face normal without camera-dependent flip. |
| Rotated group/component containing a wall | Instance stays in the wall's entities context and cuts the intended face. |
| Slanted wall face | Component is coplanar; tangent/up are stable and the array grows consistently. |
| Non-zero model axes | Same orientation/cutting result as ordinary copy/paste. |

The automated fake-Geom seam verifies transform orientation, epsilon, and
world-to-context conversion. Actual `glued_to` cutting behaviour still requires
the SketchUp 2026 checks above.
