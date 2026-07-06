# Window Native Copy Tool Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new experimental window array tool that preserves the current working tool and builds arrays from a native-like first window placement plus planar copies.

**Architecture:** Keep the current `Раскладка окон` untouched. Add a parallel tool/controller pair for `Раскладка окон (Native Copy)` that separates two concerns: first-window orientation and array growth direction. The first window will be derived from a face-relative placement state, and the rest of the array will be planar translations of that first transform.

**Tech Stack:** SketchUp Ruby API, existing `component_library_browser` plugin structure, HtmlDialog palette, debug logging.

---

## Chunk 1: Experimental Tool Skeleton

### Task 1: Add a separate experimental controller entry point

**Files:**
- Modify: `C:\Users\drale\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins\component_library_browser\main.rb`
- Create: `C:\Users\drale\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins\component_library_browser\array\win_array_native_controller.rb`
- Test: manual SketchUp smoke check

- [ ] **Step 1: Write the failing test**

Manual expectation:
- current `Раскладка окон` still opens
- new experimental command opens separately
- both commands can coexist

- [ ] **Step 2: Run test to verify it fails**

Run in SketchUp:
- reload plugin
- verify new command/button is missing before implementation

- [ ] **Step 3: Write minimal implementation**

Create a new controller class by cloning only the session wiring from `win_array_controller.rb`, but keep a new class/module name and separate command registration.

- [ ] **Step 4: Run test to verify it passes**

Run in SketchUp:
- reload plugin
- verify both window tools open independently

- [ ] **Step 5: Commit**

```bash
git add "component_library_browser/main.rb" "component_library_browser/array/win_array_native_controller.rb" "docs/superpowers/plans/2026-03-12-window-native-copy-tool.md"
git commit -m "feat: add experimental native-copy window tool entry point"
```

## Chunk 2: First-Window Placement State

### Task 2: Preserve full source attachment frame for pipette-source

**Files:**
- Modify: `C:\Users\drale\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins\component_library_browser\array\win_array_native_controller.rb`
- Test: manual SketchUp test with source pipetted from model

- [ ] **Step 1: Write the failing test**

Manual expectation:
- choosing a window with pipette on one wall and previewing on the opposite parallel wall should keep the same window roll/orientation as native copy/paste

- [ ] **Step 2: Run test to verify it fails**

Run in SketchUp with the current experiment stub:
- pipette an existing glued/cutting window
- preview on opposite face
- confirm first preview window roll is wrong

- [ ] **Step 3: Write minimal implementation**

Store a full world-space source face frame and source instance transform:
- `source_face_frame = { origin, x, y, z }`
- `source_window_transform`
- derive `relative_transform = source_face_frame.inverse * source_window_transform`

- [ ] **Step 4: Run test to verify it passes**

Run in SketchUp:
- pipette source instance
- preview on opposite face
- first window matches native copy/paste orientation

- [ ] **Step 5: Commit**

```bash
git add "component_library_browser/array/win_array_native_controller.rb"
git commit -m "fix: preserve source attachment frame for native-copy windows"
```

### Task 3: Add target face frame reconstruction

**Files:**
- Modify: `C:\Users\drale\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins\component_library_browser\tools\array_tool.rb`
- Test: manual SketchUp test on XY/YZ/ZX and opposite faces

- [ ] **Step 1: Write the failing test**

Manual expectation:
- first window transform should come from `target_face_frame * relative_transform`
- no extra 90/180 roll on opposite parallel faces

- [ ] **Step 2: Run test to verify it fails**

Run in SketchUp:
- compare current first preview to native copy/paste
- confirm mismatch

- [ ] **Step 3: Write minimal implementation**

For the experimental tool only:
- build a stable `target_face_frame`
- compute `base_transform = target_face_frame * relative_transform`
- stop using `rotation_transform_between_vectors` for experimental pipette path

- [ ] **Step 4: Run test to verify it passes**

Run in SketchUp:
- same pipette source
- preview on opposite face
- first window now matches native copy/paste

- [ ] **Step 5: Commit**

```bash
git add "component_library_browser/tools/array_tool.rb"
git commit -m "fix: derive native-copy window placement from relative face transform"
```

## Chunk 3: Library Source and Stable Grid Directions

### Task 4: Add first-window base transform for library source without hover probe

**Files:**
- Modify: `C:\Users\drale\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins\component_library_browser\array\win_array_native_controller.rb`
- Modify: `C:\Users\drale\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins\component_library_browser\tools\array_tool.rb`
- Test: manual SketchUp test with window selected from library

- [ ] **Step 1: Write the failing test**

Manual expectation:
- library-selected source on a YZ wall should preview the same orientation as ordinary native insertion from the library

- [ ] **Step 2: Run test to verify it fails**

Run in SketchUp:
- choose the same window from library
- compare native placement vs experimental tool preview
- confirm 90-degree mismatch

- [ ] **Step 3: Write minimal implementation**

For the experimental tool only:
- do not probe on hover
- on point lock / apply-prep, derive a one-time base placement state for the first window
- cache it in the locked target snapshot

- [ ] **Step 4: Run test to verify it passes**

Run in SketchUp:
- choose source from library
- hover and lock target
- preview first window matches native library insertion on the same face

- [ ] **Step 5: Commit**

```bash
git add "component_library_browser/array/win_array_native_controller.rb" "component_library_browser/tools/array_tool.rb"
git commit -m "fix: use one-time base placement for library windows in native-copy tool"
```

### Task 5: Make grid growth deterministic and independent of camera

**Files:**
- Modify: `C:\Users\drale\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins\component_library_browser\tools\array_tool.rb`
- Test: manual SketchUp test with 5x3 array on multiple faces

- [ ] **Step 1: Write the failing test**

Manual expectation:
- array always grows right and up from the anchor point
- camera movement does not change grid direction

- [ ] **Step 2: Run test to verify it fails**

Run in SketchUp:
- test two opposite vertical faces
- confirm one face grows left/down

- [ ] **Step 3: Write minimal implementation**

For the experimental tool only:
- separate component basis from layout basis
- compute layout `up` from world Z projected onto face plane
- compute layout `right` from a deterministic horizontal axis on the face
- stop using camera-flipped normal for `layout_axes`

- [ ] **Step 4: Run test to verify it passes**

Run in SketchUp:
- 5x3 array on YZ, ZX, and opposite faces
- verify growth is always right/up

- [ ] **Step 5: Commit**

```bash
git add "component_library_browser/tools/array_tool.rb"
git commit -m "fix: stabilize native-copy window grid direction"
```

## Chunk 4: Apply, Verification, and Comparison

### Task 6: Keep apply path identical to preview path

**Files:**
- Modify: `C:\Users\drale\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins\component_library_browser\array\win_array_native_controller.rb`
- Modify: `C:\Users\drale\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins\component_library_browser\tools\array_tool.rb`
- Test: manual SketchUp apply verification

- [ ] **Step 1: Write the failing test**

Manual expectation:
- first apply instance matches first preview instance
- cutting/gluing still works

- [ ] **Step 2: Run test to verify it fails**

Run in SketchUp:
- compare preview first window to resulting first placed window
- confirm any mismatch before final cleanup

- [ ] **Step 3: Write minimal implementation**

Make sure experimental tool:
- uses the same locked base transform for preview and apply
- keeps current `glued_to` and cut-opening insertion flow

- [ ] **Step 4: Run test to verify it passes**

Run in SketchUp:
- apply 5x3 array
- verify first window orientation, right/up growth, and wall cutting

- [ ] **Step 5: Commit**

```bash
git add "component_library_browser/array/win_array_native_controller.rb" "component_library_browser/tools/array_tool.rb"
git commit -m "fix: align preview and apply for native-copy window tool"
```

### Task 7: Manual acceptance comparison against current tool

**Files:**
- Modify: `C:\Users\drale\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins\docs\WINDOW_NATIVE_ORIENTATION_FIX_PLAN.md`

- [ ] **Step 1: Write the failing test**

Acceptance checklist:
- source from library works
- source from model works
- opposite face keeps orientation
- grid grows right/up
- cut opening still works

- [ ] **Step 2: Run test to verify it fails**

Run current stable tool and experimental tool side by side on the same scene.

- [ ] **Step 3: Write minimal implementation**

Document final comparison and which tool should be kept.

- [ ] **Step 4: Run test to verify it passes**

User verifies which tool behaves closer to native copy/paste.

- [ ] **Step 5: Commit**

```bash
git add "docs/WINDOW_NATIVE_ORIENTATION_FIX_PLAN.md"
git commit -m "docs: record native-copy window tool comparison"
```

Plan complete and saved to `docs/superpowers/plans/2026-03-12-window-native-copy-tool.md`. Ready to execute?
