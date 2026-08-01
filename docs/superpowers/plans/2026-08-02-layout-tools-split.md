# Layout tools split Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose independent brick/grid and window layout tools while keeping their shared placement maths small, pure, and safe to reload.

**Architecture:** Keep `Tools::ArrayTool` as the existing interaction/preview implementation, but remove configuration-driven mode selection from it. Two thin public boundaries (`BrickLayoutTool` and `WindowLayoutTool`) select a fixed layout kind at construction; the existing controllers own their own palette, lifecycle, callbacks, and session namespace. `WindowPlacement` remains the window-only pure placement primitive; a new `LayoutGeometry` module holds only mode-neutral grid maths.

**Tech Stack:** SketchUp Ruby API, Ruby/Minitest contract tests, static UI-contract test.

---

### Task 1: Lock down public layout-tool boundaries

**Files:**
- Modify: `test/window_insertion_contract_test.rb`
- Modify: `component_library_browser/main.rb`
- Modify: `component_library_browser/array/array_controller.rb`
- Modify: `component_library_browser/array/win_array_controller.rb`

- [ ] **Step 1: Write the failing contract tests** for brick/window public tool initialization, fixed dispatch, namespaced session accessors, one menu/toolbar item per public tool, and no native-copy mode.
- [ ] **Step 2: Run the window contract test** and confirm it fails because the public tool files and fixed layout-kind boundary do not exist.
- [ ] **Step 3: Implement the smallest fixed public tool boundaries** and point each controller at only its corresponding boundary; retain existing callback names and command keys.
- [ ] **Step 4: Run the window contract test** and confirm it passes.

### Task 2: Extract mode-neutral placement primitives

**Files:**
- Create: `component_library_browser/tools/layout_geometry.rb`
- Modify: `component_library_browser/tools/array_tool.rb`
- Modify: `component_library_browser/main.rb`
- Modify: `test/window_insertion_contract_test.rb`

- [ ] **Step 1: Add a failing geometry contract** for a pure grid offset/row-shift helper that does not accept a global mode.
- [ ] **Step 2: Run the focused test** and confirm it fails because `LayoutGeometry` is missing.
- [ ] **Step 3: Add the pure helper and have legacy `ArrayTool` consume it**; use an explicit immutable layout kind instead of `params['mode']`.
- [ ] **Step 4: Run the focused test and all Ruby contracts** and confirm they pass.

### Task 3: Reload/documentation/verification

**Files:**
- Modify: `component_library_browser/main.rb`
- Modify: `test/window_insertion_contract_test.rb`
- Create: `docs/decisions/2026-08-layout-tools-split.md`

- [ ] **Step 1: Add failing static contracts** proving safe reload includes each extracted file and obsolete native-copy production code is absent.
- [ ] **Step 2: Run the focused test** and confirm it fails.
- [ ] **Step 3: Add all extracted files to the existing reload list and record the responsibility split plus the SketchUp 2026 smoke matrix.**
- [ ] **Step 4: Run Ruby tests, production syntax checks, static UI checks, icon exporter, and inspect menu/toolbar command mappings.**
- [ ] **Step 5: Commit the focused change.**
