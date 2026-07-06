# WINDOW_NATIVE_ORIENTATION_FIX_PLAN

## Диагностика

### 1. Где в проекте выбирается target face

- [`component_library_browser/tools/array_tool.rb`](C:/Users/drale/AppData/Roaming/SketchUp/SketchUp%202024/SketchUp/Plugins/component_library_browser/tools/array_tool.rb)
  - `onMouseMove`
  - `update_windows_hover_target`
  - `current_windows_preview_target`
  - `windows_target_snapshot_for_apply`
  - `windows_target_from_runtime_state`
  - `selected_face_target_snapshot`
  - `build_windows_target_snapshot`
  - `raycast_face_from_view`
  - `face_transform_from_input`

### 2. Где строится preview transform

- [`component_library_browser/tools/array_tool.rb`](C:/Users/drale/AppData/Roaming/SketchUp/SketchUp%202024/SketchUp/Plugins/component_library_browser/tools/array_tool.rb)
  - `current_frame`
  - `current_frame_from_windows_target`
  - `build_transforms`
  - `draw`
  - `draw_preview`
  - `draw_primary_preview`

### 3. Где строится apply transform

- [`component_library_browser/tools/array_tool.rb`](C:/Users/drale/AppData/Roaming/SketchUp/SketchUp%202024/SketchUp/Plugins/component_library_browser/tools/array_tool.rb)
  - `windows_target_snapshot_for_apply`
  - `windows_frame_for_apply`
  - `transforms_for_apply`
  - `build_transforms`

### 4. Где рассчитываются локальные оси на плоскости

- [`component_library_browser/tools/array_tool.rb`](C:/Users/drale/AppData/Roaming/SketchUp/SketchUp%202024/SketchUp/Plugins/component_library_browser/tools/array_tool.rb)
  - `window_axes_from_normal`
  - `generic_axes_from_normal`
  - `base_axes_for_mode`
  - `layout_v_axis`
  - `resolve_frame_normal`
  - `build_windows_target_snapshot`

### 5. Где создаются реальные instances

- [`component_library_browser/array/win_array_controller.rb`](C:/Users/drale/AppData/Roaming/SketchUp/SketchUp%202024/SketchUp/Plugins/component_library_browser/array/win_array_controller.rb)
  - `apply`
  - `add_instance_in_entities`
  - `glue_instance_to_face`
  - `flip_world_transform`

## Зафиксированные наблюдения

- Preview уже показывает неверную ориентацию на части плоскостей.
- Apply наследует ту же проблему, потому что использует тот же `build_transforms`.
- Для одного и того же окна стандартная вставка SketchUp на ту же грань даёт корректную ориентацию.
- Следовательно, ошибка не в компоненте и не в `glued_to`, а в логике построения transform внутри инструмента.

## Текущая гипотеза

- Инструмент сейчас подменяет нативную ориентацию SketchUp собственной математикой.
- Для glued/cutting окна это даёт ошибки на 90° или 180° на части face.
- В текущем состоянии отдельный оконный контроллер ещё и передаёт в `ArrayTool` режим `mode = 'brick'`, из-за чего preview идёт через brick-style pipeline, а не через специализированный оконный.
- Из-за этого первый preview-instance уже может иметь неверный basis, а массив просто повторяет эту ошибку.

## План исправления

### Цель

Режим ОКНА должен ориентироваться как стандартный placement SketchUp, а массив должен строиться как копии корректно ориентированного первого окна.

### План работ

1. Прекратить использовать brick-style preview pipeline для оконного контроллера.
2. Выделить для режима ОКНА один корректный `base_transform` первого окна на target face.
3. Не пересчитывать orientation для каждого экземпляра массива с нуля.
4. Строить массив как:
   - корректный `base_transform` первого окна
   - плюс плоские смещения по двум осям стены, как Move+Ctrl
5. Убедиться, что preview и apply используют один и тот же базовый transform.
6. Оставить рабочую механику:
   - вставка в нужный `Entities`-контекст
   - `instance.glued_to = face`
   - cut opening
7. Добавить временный debug log:
   - имя прототипа
   - normal целевой грани
   - front/back сведения по грани
   - preview transform
   - apply transform
   - delta между ними
   - статус `glued_to`

## Что именно нужно проверить в коде при правке

1. Совпадают ли transform preview и apply.
2. Где появляется лишний поворот:
   - в preview
   - в apply
   - в вычислении осей
   - в переносе из локальных осей компонента в оси face
3. Учитываются ли axes самого component definition.
4. Не зависит ли ошибка от front/back стороны face.
5. Не меняется ли знак одной из осей на некоторых normals.
6. Не добавляется ли скрытый поворот вокруг normal.
7. Не пытается ли код “исправить” orientation после получения base transform и тем самым ломает нативную постановку.
