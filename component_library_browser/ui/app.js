(function () {
  const state = {
    lib_root: "",
    categories: [],
    pinned_categories: [],
    items: [],
    in_model_items: [],
    all_tags: [],
    recent_limit: 50,
    scope: "all",
    search: "",
    weight_filter: "all",
    sidebar_collapsed: false,
    inspector_collapsed: false,
    card_size: "medium",
    page_size: 25,
    current_page: 1,
    insert_options: {
      place_on_surface: true,
      align_to_normal: false,
      random_quadrant: false,
      drop_to_ground: false,
      random_step_degrees: 90,
    },
    status_text: "",
    heavy_faces_threshold: 200000,
    selected_ref: null,
    context_item: null,
    context_category: null,
    focus_item_id: null,
    pending_select_category: null,
    array_pick_mode: false,
    array_pick_message: "",
    array_tool_active: false,
    selection_state: {
      count: 0,
      replace_library_from_selection_allowed: false,
    },
  };

  const dom = {};

  const CALLBACK_FALLBACKS = {
    start_brush: ["start_brush_item"],
    replace_selection: ["replace_with_library_item"],
    regenerate_thumbnail: ["regenerate_preview_item"],
    open_folder: ["item_open_folder"],
    show_in_folder: ["item_reveal_file"],
    update_item_fields: ["edit_item"],
    modeltab_save_to_library: ["save_in_model_definition"],
    modeltab_select_all: ["select_all_in_model"],
    replace_selection_model: ["replace_with_model_definition"],
  };

  const PLACEMENT_TYPES = [
    { value: "free", label: "Свободный объект", short: "" },
    { value: "ground", label: "На земле", short: "Земля" },
    { value: "surface", label: "На поверхности", short: "Поверхность" },
    { value: "wall", label: "На стене", short: "Стена" },
    { value: "ceiling", label: "Потолочный", short: "Потолок" },
    { value: "opening", label: "В проёме", short: "Проём" },
  ];

  const PLACEMENT_ANCHORS = [
    { value: "center_bottom", label: "Центр снизу" },
    { value: "corner_lb", label: "Левый нижний угол" },
    { value: "corner_rb", label: "Правый нижний угол" },
    { value: "opening_center", label: "Центр проёма" },
    { value: "geometric_center", label: "Геометрический центр" },
    { value: "custom", label: "Пользовательская" },
  ];

  function init() {
    setupErrorForwarding();
    document.addEventListener("contextmenu", (event) => event.preventDefault());
    cacheDom();
    populatePlacementSelects();
    if (dom.inspectorReplaceFromSelection) {
      dom.inspectorReplaceFromSelection.disabled = false;
      dom.inspectorReplaceFromSelection.removeAttribute("disabled");
    }
    bindBaseEvents();
    render();
    ruby("ready");
    ruby("refresh_selection_state");
    window.setInterval(() => {
      ruby("refresh_selection_state");
    }, 1200);
  }

  function setupErrorForwarding() {
    window.addEventListener("error", (event) => {
      ruby("js_error", {
        message: event.message || "Неизвестная JS ошибка",
        source: event.filename || "",
        line: event.lineno || 0,
        column: event.colno || 0,
        stack: event.error && event.error.stack ? String(event.error.stack) : "",
      });
    });

    window.addEventListener("unhandledrejection", (event) => {
      const reason = event.reason;
      ruby("js_error", {
        message: reason && reason.message ? String(reason.message) : String(reason || "Unhandled rejection"),
        source: "promise",
        line: 0,
        column: 0,
        stack: reason && reason.stack ? String(reason.stack) : "",
      });
    });
  }

  function cacheDom() {
    dom.appShell = document.getElementById("app-shell");
    dom.sidebarToggle = document.getElementById("sidebar-toggle");
    dom.search = document.getElementById("search");
    dom.refreshBtn = document.getElementById("refresh-btn");
    dom.refreshMenuBtn = document.getElementById("refresh-menu-btn");
    dom.refreshStatus = document.getElementById("refresh-status");
    dom.weightFilter = document.getElementById("weight-filter");
    dom.pinnedTabs = document.getElementById("pinned-tabs");
    dom.statusLine = document.getElementById("status-line");
    dom.arrayPickBanner = document.getElementById("array-pick-banner");
    dom.categoryList = document.getElementById("category-list");
    dom.cardsGrid = document.getElementById("cards-grid");
    dom.cardTemplate = document.getElementById("card-template");

    dom.cardSizeButtons = Array.from(document.querySelectorAll(".size-btn"));
    dom.pageSizeButtons = Array.from(document.querySelectorAll(".page-size-btn"));
    dom.pagePrev = document.getElementById("page-prev");
    dom.pageNext = document.getElementById("page-next");
    dom.pageNumbers = document.getElementById("page-numbers");
    dom.pageInfo = document.getElementById("page-info");

    dom.filterButtons = Array.from(document.querySelectorAll(".filter-btn"));
    dom.refreshInModelBtn = document.getElementById("refresh-in-model-btn");

    dom.categoryAdd = document.getElementById("category-add");
    dom.categoryRename = document.getElementById("category-rename");
    dom.categoryDelete = document.getElementById("category-delete");
    dom.categoryRegen = document.getElementById("category-regen");

    dom.saveSelectedBtn = document.getElementById("save-selected-btn");
    dom.settingsBtn = document.getElementById("settings-btn");

    dom.settingsBackdrop = document.getElementById("settings-backdrop");
    dom.settingsRootPath = document.getElementById("settings-root-path");
    dom.settingsHeavyThreshold = document.getElementById("settings-heavy-threshold");
    dom.settingsSaveThreshold = document.getElementById("settings-save-threshold");
    dom.settingsChangeRoot = document.getElementById("settings-change-root");
    dom.settingsScan = document.getElementById("settings-scan");
    dom.settingsRegenAll = document.getElementById("settings-regen-all");
    dom.settingsExportPack = document.getElementById("settings-export-pack");
    dom.settingsImportPack = document.getElementById("settings-import-pack");
    dom.settingsClose = document.getElementById("settings-close");

    dom.inspectorTitle = document.getElementById("inspector-title");
    dom.inspectorToggle = document.getElementById("inspector-toggle");
    dom.inspectorExpand = document.getElementById("inspector-expand");
    dom.inspectorEmpty = document.getElementById("inspector-empty");

    dom.inspectorLibrary = document.getElementById("inspector-library");
    dom.inspectorModel = document.getElementById("inspector-model");
    dom.inspectorInsertOptions = document.getElementById("inspector-insert-options");

    dom.inspectorPreview = document.getElementById("inspector-preview");
    dom.inspectorOpenLightbox = document.getElementById("inspector-open-lightbox");
    dom.inspectorRegenPreview = document.getElementById("inspector-regen-preview");

    dom.inspectorName = document.getElementById("inspector-name");
    dom.inspectorCategory = document.getElementById("inspector-category");
    dom.inspectorAddCategory = document.getElementById("inspector-add-category");
    dom.inspectorDescription = document.getElementById("inspector-description");

    dom.inspectorTagInput = document.getElementById("inspector-tag-input");
    dom.inspectorTagAdd = document.getElementById("inspector-tag-add");
    dom.inspectorTagSuggestions = document.getElementById("inspector-tag-suggestions");
    dom.inspectorTagQuick = document.getElementById("inspector-tag-quick");
    dom.inspectorTags = document.getElementById("inspector-tags");

    dom.placementSection = document.getElementById("placement-section");
    dom.placementType = document.getElementById("placement-type");
    dom.placementAnchor = document.getElementById("placement-anchor");
    dom.placementOffsetZ = document.getElementById("placement-offset-z");
    dom.placementCutRow = document.getElementById("placement-cut-row");
    dom.placementCutOpening = document.getElementById("placement-cut-opening");

    dom.inspectorInsert = document.getElementById("inspector-insert");
    dom.inspectorBrush = document.getElementById("inspector-brush");
    dom.inspectorReplace = document.getElementById("inspector-replace");
    dom.inspectorReplaceFromSelection = document.getElementById("inspector-replace-from-selection");
    dom.inspectorShowFile = document.getElementById("inspector-show-file");
    dom.inspectorOpenFolder = document.getElementById("inspector-open-folder");
    dom.inspectorToggleFavorite = document.getElementById("inspector-toggle-favorite");
    dom.inspectorDelete = document.getElementById("inspector-delete");

    dom.modelName = document.getElementById("model-name");
    dom.modelCount = document.getElementById("model-count");
    dom.modelSave = document.getElementById("model-save");
    dom.modelReplace = document.getElementById("model-replace");
    dom.modelSelectAll = document.getElementById("model-select-all");

    dom.optionSurface = document.getElementById("opt-surface");
    dom.optionNormal = document.getElementById("opt-normal");
    dom.optionRandom = document.getElementById("opt-random");
    dom.optionRandomStep = document.getElementById("opt-random-step");
    dom.optionGround = document.getElementById("opt-ground");
    dom.insertOptionsWrap = document.getElementById("insert-options");

    dom.lightboxBackdrop = document.getElementById("lightbox-backdrop");
    dom.lightboxImage = document.getElementById("lightbox-image");
    dom.lightboxClose = document.getElementById("lightbox-close");

    dom.cardContextMenu = document.getElementById("card-context-menu");
    dom.categoryContextMenu = document.getElementById("category-context-menu");
  }

  function bindBaseEvents() {
    dom.filterButtons.forEach((button) => {
      button.addEventListener("click", () => {
        const nextScope = button.dataset.filter || "all";
        state.scope = nextScope;
        state.current_page = 1;
        if (nextScope === "in_model") ruby("refresh_in_model");
        render();
      });
    });
    if (dom.refreshInModelBtn) {
      dom.refreshInModelBtn.addEventListener("click", () => {
        ruby("refresh_in_model");
      });
    }
    if (dom.refreshBtn) {
      dom.refreshBtn.addEventListener("click", onRefreshQuick);
      dom.refreshBtn.addEventListener("contextmenu", (event) => {
        event.preventDefault();
        onRefreshMenu();
      });
    }
    if (dom.refreshMenuBtn) {
      dom.refreshMenuBtn.addEventListener("click", onRefreshMenu);
    }

    dom.search.addEventListener("input", () => {
      state.search = String(dom.search.value || "");
      state.current_page = 1;
      renderCardsWithPagination();
    });

    dom.weightFilter.addEventListener("change", () => {
      state.weight_filter = dom.weightFilter.value || "all";
      state.current_page = 1;
      renderCardsWithPagination();
    });

    dom.cardSizeButtons.forEach((button) => {
      button.addEventListener("click", () => {
        state.card_size = button.dataset.size || "medium";
        renderCardSize();
        renderCardsWithPagination();
      });
    });

    dom.pageSizeButtons.forEach((button) => {
      button.addEventListener("click", () => {
        const size = Number(button.dataset.pageSize || 25);
        state.page_size = [10, 25, 50].includes(size) ? size : 25;
        state.current_page = 1;
        renderCardsWithPagination();
      });
    });

    dom.pagePrev.addEventListener("click", () => {
      if (state.current_page <= 1) return;
      state.current_page -= 1;
      renderCardsWithPagination();
    });

    dom.pageNext.addEventListener("click", () => {
      state.current_page += 1;
      renderCardsWithPagination();
    });

    dom.categoryAdd.addEventListener("click", onCategoryAdd);
    dom.categoryRename.addEventListener("click", onCategoryRename);
    dom.categoryDelete.addEventListener("click", onCategoryDelete);
    dom.categoryRegen.addEventListener("click", onCategoryRegenerate);

    dom.saveSelectedBtn.addEventListener("click", onSaveSelected);

    dom.sidebarToggle.addEventListener("click", () => {
      state.sidebar_collapsed = !state.sidebar_collapsed;
      renderSidebarState();
    });

    dom.settingsBtn.addEventListener("click", openSettingsModal);
    dom.settingsChangeRoot.addEventListener("click", () => ruby("open_settings"));
    dom.settingsScan.addEventListener("click", () => ruby("scan_library"));
    dom.settingsRegenAll.addEventListener("click", () => ruby("regenerate_previews_all"));
    dom.settingsExportPack.addEventListener("click", () => ruby("export_pack"));
    dom.settingsImportPack.addEventListener("click", () => ruby("import_pack"));
    dom.settingsSaveThreshold.addEventListener("click", onSaveThreshold);
    dom.settingsClose.addEventListener("click", closeSettingsModal);
    dom.settingsBackdrop.addEventListener("click", (event) => {
      if (event.target === dom.settingsBackdrop) closeSettingsModal();
    });

    dom.inspectorToggle.addEventListener("click", toggleInspectorCollapsed);
    dom.inspectorExpand.addEventListener("click", toggleInspectorCollapsed);

    dom.inspectorPreview.addEventListener("click", openLightboxFromInspector);
    dom.inspectorOpenLightbox.addEventListener("click", openLightboxFromInspector);
    dom.inspectorRegenPreview.addEventListener("click", onInspectorRegeneratePreview);

    dom.inspectorName.addEventListener("blur", () => saveInspectorFields({ name: dom.inspectorName.value }));
    dom.inspectorName.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        dom.inspectorName.blur();
      }
    });

    dom.inspectorCategory.addEventListener("change", () => saveInspectorFields({ category: dom.inspectorCategory.value }));
    dom.inspectorAddCategory.addEventListener("click", onInspectorAddCategory);
    dom.inspectorDescription.addEventListener("blur", () => saveInspectorFields({ description: dom.inspectorDescription.value }));

    if (dom.placementType) {
      dom.placementType.addEventListener("change", () => {
        renderPlacementCutRow();
        saveInspectorFields({ placement: readPlacementFromUI() });
      });
    }
    if (dom.placementAnchor) {
      dom.placementAnchor.addEventListener("change", () => saveInspectorFields({ placement: readPlacementFromUI() }));
    }
    if (dom.placementOffsetZ) {
      dom.placementOffsetZ.addEventListener("change", () => saveInspectorFields({ placement: readPlacementFromUI() }));
    }
    if (dom.placementCutOpening) {
      dom.placementCutOpening.addEventListener("change", () => saveInspectorFields({ placement: readPlacementFromUI() }));
    }

    dom.inspectorTagAdd.addEventListener("click", () => addInspectorTag(dom.inspectorTagInput.value));
    dom.inspectorTagInput.addEventListener("input", () => {
      renderQuickTagSuggestions(dom.inspectorTagInput.value);
    });
    dom.inspectorTagInput.addEventListener("focus", () => {
      renderQuickTagSuggestions(dom.inspectorTagInput.value);
    });
    dom.inspectorTagInput.addEventListener("blur", () => {
      window.setTimeout(() => {
        if (dom.inspectorTagQuick) dom.inspectorTagQuick.innerHTML = "";
      }, 120);
    });
    dom.inspectorTagInput.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === ",") {
        event.preventDefault();
        addInspectorTag(dom.inspectorTagInput.value);
      }
    });
    dom.inspectorInsert.addEventListener("click", onInspectorInsert);
    dom.inspectorBrush.addEventListener("click", onInspectorBrush);
    dom.inspectorReplace.addEventListener("click", onInspectorReplace);
    if (dom.inspectorReplaceFromSelection) {
      dom.inspectorReplaceFromSelection.addEventListener("click", onInspectorReplaceFromSelection);
    }
    dom.inspectorShowFile.addEventListener("click", onInspectorShowFile);
    dom.inspectorOpenFolder.addEventListener("click", onInspectorOpenFolder);
    dom.inspectorToggleFavorite.addEventListener("click", onInspectorToggleFavorite);
    dom.inspectorDelete.addEventListener("click", onInspectorDelete);

    dom.modelSave.addEventListener("click", onModelSaveToLibrary);
    dom.modelReplace.addEventListener("click", onModelReplaceSelection);
    dom.modelSelectAll.addEventListener("click", onModelSelectAll);

    if (dom.insertOptionsWrap) {
      dom.insertOptionsWrap.addEventListener("change", (event) => {
        const input = event.target.closest("input[data-insert-opt]");
        if (!input) return;
        const key = input.dataset.insertOpt || "";
        if (!key) return;
        state.insert_options = state.insert_options || {};
        state.insert_options[key] = !!input.checked;
        renderInsertOptions();
        ruby("set_insert_option", { key, value: !!input.checked });
      });
    }
    if (dom.optionRandomStep) {
      dom.optionRandomStep.addEventListener("change", () => {
        const step = Number(dom.optionRandomStep.value || 90);
        state.insert_options = state.insert_options || {};
        state.insert_options.random_step_degrees = step;
        renderInsertOptions();
        ruby("set_insert_option", { key: "random_step_degrees", value: step });
      });
    }

    dom.lightboxClose.addEventListener("click", closeLightbox);
    dom.lightboxBackdrop.addEventListener("click", (event) => {
      if (event.target === dom.lightboxBackdrop) closeLightbox();
    });

    if (dom.cardContextMenu) dom.cardContextMenu.addEventListener("click", onCardContextMenuClick);
    if (dom.categoryContextMenu) dom.categoryContextMenu.addEventListener("click", onCategoryContextMenuClick);

    document.addEventListener("click", () => {
      hideCardContextMenu();
      hideCategoryContextMenu();
    });

    document.addEventListener("keydown", onGlobalKeydown);
  }

  function ruby(name, payload) {
    if (!window.sketchup) return false;

    const names = [name, ...(CALLBACK_FALLBACKS[name] || [])];
    let called = false;

    names.some((callbackName) => {
      if (typeof window.sketchup[callbackName] !== "function") return false;
      called = true;
      if (payload === undefined) {
        window.sketchup[callbackName]();
      } else if (typeof payload === "string") {
        window.sketchup[callbackName](payload);
      } else {
        window.sketchup[callbackName](JSON.stringify(payload));
      }
      return true;
    });

    return called;
  }

  function onCategoryAdd() {
    const name = prompt("Имя новой категории:");
    if (!name) return;
    ruby("category_add", name);
  }

  function onCategoryRename() {
    if (!state.scope.startsWith("category:")) {
      alert("Выберите категорию в списке слева.");
      return;
    }
    const oldName = state.scope.replace("category:", "");
    const nextName = prompt("Новое имя категории:", oldName);
    if (!nextName || nextName === oldName) return;
    ruby("category_rename", { old: oldName, new: nextName });
  }

  function onCategoryDelete() {
    if (!state.scope.startsWith("category:")) {
      alert("Выберите категорию в списке слева.");
      return;
    }
    ruby("category_delete", state.scope.replace("category:", ""));
  }

  function onCategoryRegenerate() {
    if (!state.scope.startsWith("category:")) {
      alert("Выберите категорию в списке слева.");
      return;
    }
    ruby("regenerate_previews_category", state.scope.replace("category:", ""));
  }

  function onSaveSelected() {
    const payload = {};
    if (state.scope.startsWith("category:")) payload.category = state.scope.replace("category:", "");
    ruby("save_selected", payload);
  }

  function onRefreshQuick() {
    ruby("refresh_index_only");
  }

  function onRefreshMenu() {
    const mode = prompt(
      "Выберите режим обновления:\n1 — Обновить список (быстро)\n2 — Сканировать папку (глубоко)",
      "1"
    );
    if (mode === null) return;
    if (String(mode).trim() === "2") {
      ruby("scan_library_folder");
      return;
    }
    ruby("refresh_index_only");
  }

  function onSaveThreshold() {
    const value = Number(dom.settingsHeavyThreshold.value || 0);
    if (!Number.isFinite(value) || value <= 0) {
      alert("Введите корректный порог (число больше 0).");
      return;
    }
    state.heavy_faces_threshold = Math.floor(value);
    ruby("set_heavy_threshold", { value: state.heavy_faces_threshold });
    renderCardsWithPagination();
  }

  function openSettingsModal() {
    renderSettingsPath();
    dom.settingsBackdrop.hidden = false;
  }

  function closeSettingsModal() {
    dom.settingsBackdrop.hidden = true;
  }

  function toggleInspectorCollapsed() {
    state.inspector_collapsed = !state.inspector_collapsed;
    renderInspectorCollapsedState();
  }

  function openLightboxFromInspector() {
    const selected = selectedItem();
    if (!selected) return;
    const src = selected.thumb_url || placeholderThumb(selected.name || "Компонент");
    dom.lightboxImage.src = src;
    dom.lightboxBackdrop.hidden = false;
  }

  function closeLightbox() {
    dom.lightboxBackdrop.hidden = true;
  }

  function onInspectorRegeneratePreview() {
    const selected = selectedItem();
    if (!selected || selected.kind !== "library") return;
    ruby("regenerate_thumbnail", selected.id);
  }

  function onInspectorInsert() {
    const selected = selectedItem();
    if (!selected || selected.kind !== "library") return;
    ruby("insert_item", selected.id);
  }

  function onInspectorBrush() {
    const selected = selectedItem();
    if (!selected || selected.kind !== "library") return;
    ruby("start_brush", selected.id);
  }

  function onInspectorReplace() {
    const selected = selectedItem();
    if (!selected) return;
    if (selected.kind === "library") {
      ruby("replace_selection", selected.id);
    } else {
      ruby("replace_selection_model", selected.definition_guid);
    }
  }

  function onInspectorReplaceFromSelection() {
    const selected = selectedItem();
    if (!selected || selected.kind !== "library") return;
    const called = ruby("replace_library_item_from_selection", { id: selected.id });
    if (!called) {
      alert("Команда недоступна: callback не найден. Сделайте полный reload плагина.");
    }
  }

  function onInspectorShowFile() {
    const selected = selectedItem();
    if (!selected || selected.kind !== "library") return;
    ruby("show_in_folder", selected.id);
  }

  function onInspectorOpenFolder() {
    const selected = selectedItem();
    if (!selected || selected.kind !== "library") return;
    ruby("open_folder", selected.id);
  }
  function onInspectorToggleFavorite() {
    const selected = selectedItem();
    if (!selected || selected.kind !== "library") return;
    ruby("toggle_favorite", { id: selected.id, value: !selected.favorite });
  }

  function onInspectorDelete() {
    const selected = selectedItem();
    if (!selected || selected.kind !== "library") return;
    ruby("delete_item", selected.id);
  }

  function onModelSaveToLibrary() {
    const selected = selectedItem();
    if (!selected || selected.kind !== "in_model") return;
    ruby("modeltab_save_to_library", { definition_guid: selected.definition_guid });
  }

  function onModelReplaceSelection() {
    const selected = selectedItem();
    if (!selected || selected.kind !== "in_model") return;
    ruby("replace_selection_model", selected.definition_guid);
  }

  function onModelSelectAll() {
    const selected = selectedItem();
    if (!selected || selected.kind !== "in_model") return;
    ruby("modeltab_select_all", selected.definition_guid);
  }

  function onInspectorAddCategory() {
    const selected = selectedItem();
    if (!selected || selected.kind !== "library") return;

    const name = prompt("Имя новой категории:");
    if (!name) return;

    state.pending_select_category = String(name).trim();
    saveInspectorFields({ category: state.pending_select_category });
  }

  function addInspectorTag(rawTag) {
    const selected = selectedItem();
    if (!selected || selected.kind !== "library") return;

    const normalized = normalizeTags(rawTag.split(/[,]/g));
    if (normalized.length === 0) {
      dom.inspectorTagInput.value = "";
      return;
    }

    const current = normalizeTags(selected.tags || []);
    normalized.forEach((tag) => {
      if (!current.includes(tag)) current.push(tag);
    });
    current.sort();
    dom.inspectorTagInput.value = "";
    saveInspectorFields({ tags: current });
    renderQuickTagSuggestions("");
  }

  function removeInspectorTag(tag) {
    const selected = selectedItem();
    if (!selected || selected.kind !== "library") return;

    const current = normalizeTags(selected.tags || []).filter((value) => value !== tag);
    saveInspectorFields({ tags: current });
  }

  function saveInspectorFields(changes) {
    const selected = selectedItem();
    if (!selected || selected.kind !== "library") return;

    const payload = {
      id: selected.id,
      name: selected.name,
      category: selected.category,
      description: selected.description || "",
      tags: normalizeTags(selected.tags || []),
      placement: normalizePlacement(selected.placement),
    };

    if (Object.prototype.hasOwnProperty.call(changes, "name")) payload.name = String(changes.name || "").trim();
    if (Object.prototype.hasOwnProperty.call(changes, "category")) payload.category = String(changes.category || "").trim();
    if (Object.prototype.hasOwnProperty.call(changes, "description")) payload.description = String(changes.description || "").trim();
    if (Object.prototype.hasOwnProperty.call(changes, "tags")) payload.tags = normalizeTags(changes.tags || []);
    if (Object.prototype.hasOwnProperty.call(changes, "placement")) payload.placement = normalizePlacement(changes.placement);

    if (!payload.name) {
      alert("Введите имя.");
      dom.inspectorName.focus();
      return;
    }

    if (!payload.category) {
      alert("Введите категорию.");
      dom.inspectorCategory.focus();
      return;
    }

    const savedViaFields = ruby("update_item_fields", payload);

    // Запасной путь: если основной колбэк не найден, пробуем отдельный колбэк паспорта размещения.
    // Отсутствие колбэка не роняет UI и не мешает сохранению остальных полей.
    if (!savedViaFields) {
      try {
        ruby("update_item_placement", { id: payload.id, placement: payload.placement });
      } catch (error) {
        // Колбэк паспорта размещения необязателен.
      }
    }
  }

  function populatePlacementSelects() {
    const fill = (control, entries) => {
      if (!control) return;
      control.innerHTML = "";
      entries.forEach((entry) => {
        const option = document.createElement("option");
        option.value = entry.value;
        option.textContent = entry.label;
        control.appendChild(option);
      });
    };
    fill(dom.placementType, PLACEMENT_TYPES);
    fill(dom.placementAnchor, PLACEMENT_ANCHORS);
  }

  function normalizePlacement(raw) {
    const source = raw && typeof raw === "object" ? raw : {};
    const typeEntry = PLACEMENT_TYPES.find((entry) => entry.value === source.type);
    const anchorEntry = PLACEMENT_ANCHORS.find((entry) => entry.value === source.anchor);
    const offsetRaw = Number(source.offset_z);
    return {
      type: typeEntry ? typeEntry.value : "free",
      anchor: anchorEntry ? anchorEntry.value : "center_bottom",
      offset_z: Number.isFinite(offsetRaw) && offsetRaw > 0 ? offsetRaw : 0,
      cut_opening: typeEntry && typeEntry.value === "opening" ? !!source.cut_opening : false,
    };
  }

  function renderPlacementEditor(item) {
    if (!dom.placementType) return;
    const placement = normalizePlacement(item && item.placement);
    dom.placementType.value = placement.type;
    dom.placementAnchor.value = placement.anchor;
    setControlValue(dom.placementOffsetZ, String(placement.offset_z));
    dom.placementCutOpening.checked = placement.cut_opening;
    renderPlacementCutRow();
  }

  function renderPlacementCutRow() {
    if (!dom.placementCutRow) return;
    dom.placementCutRow.hidden = dom.placementType.value !== "opening";
  }

  function readPlacementFromUI() {
    return normalizePlacement({
      type: dom.placementType ? dom.placementType.value : undefined,
      anchor: dom.placementAnchor ? dom.placementAnchor.value : undefined,
      offset_z: dom.placementOffsetZ ? Number(dom.placementOffsetZ.value) : 0,
      cut_opening: dom.placementCutOpening ? !!dom.placementCutOpening.checked : false,
    });
  }

  function placementShortLabel(type) {
    const entry = PLACEMENT_TYPES.find((candidate) => candidate.value === type);
    return entry && entry.short ? entry.short : "";
  }

  function readInsertOptionsFromUI() {
    return {
      place_on_surface: !!(state.insert_options && state.insert_options.place_on_surface),
      align_to_normal: !!(state.insert_options && state.insert_options.align_to_normal),
      random_quadrant: !!(state.insert_options && state.insert_options.random_quadrant),
      drop_to_ground: !!(state.insert_options && state.insert_options.drop_to_ground),
      random_step_degrees: Number((state.insert_options && state.insert_options.random_step_degrees) || 90),
    };
  }

  function onGlobalKeydown(event) {
    if (event.key === "Escape") {
      if (!dom.lightboxBackdrop.hidden) {
        event.preventDefault();
        closeLightbox();
        return;
      }
      hideCardContextMenu();
      hideCategoryContextMenu();
      if (!state.inspector_collapsed && selectedItem()) {
        state.inspector_collapsed = true;
        renderInspectorCollapsedState();
      }
      return;
    }

    if (event.ctrlKey && (event.key === "f" || event.key === "F")) {
      event.preventDefault();
      dom.search.focus();
      dom.search.select();
      return;
    }

    if (isTextInput(event.target)) return;
    if (state.array_pick_mode || state.array_tool_active) return;

    const selected = selectedItem();
    if (!selected) return;

    if (event.key === "Enter" && selected.kind === "library") {
      event.preventDefault();
      ruby("insert_item", selected.id);
      return;
    }

    if ((event.key === "Delete" || event.key === "Del") && selected.kind === "library") {
      event.preventDefault();
      ruby("delete_item", selected.id);
      return;
    }

    if ((event.key === "f" || event.key === "F") && !event.ctrlKey && selected.kind === "library") {
      event.preventDefault();
      ruby("toggle_favorite", { id: selected.id, value: !selected.favorite });
    }
  }

  function isTextInput(target) {
    if (!target || !(target instanceof HTMLElement)) return false;
    const tag = target.tagName.toLowerCase();
    return tag === "input" || tag === "textarea" || target.isContentEditable;
  }

  function render() {
    renderSidebarState();
    renderInspectorCollapsedState();
    renderCardSize();
    renderSettingsPath();
    renderStatus();
    renderArrayPickBanner();
    renderWeightFilter();
    renderFilterButtons();
    renderModelRefreshButton();
    renderPinnedTabs();
    renderCategoryList();
    renderCardsWithPagination();
    renderInspector();
  }

  function renderSidebarState() {
    dom.appShell.classList.toggle("sidebar-collapsed", !!state.sidebar_collapsed);
    dom.sidebarToggle.textContent = state.sidebar_collapsed ? ">>" : "<<";
    dom.sidebarToggle.title = state.sidebar_collapsed ? "Развернуть панель" : "Свернуть панель";
  }

  function renderInspectorCollapsedState() {
    dom.appShell.classList.toggle("inspector-collapsed", !!state.inspector_collapsed);
    dom.inspectorExpand.hidden = !state.inspector_collapsed;
    dom.inspectorToggle.innerHTML = state.inspector_collapsed ? "&#10094;" : "&#10095;";
  }

  function renderCardSize() {
    const size = state.card_size || "medium";
    dom.cardsGrid.classList.remove("size-small", "size-medium", "size-large");
    dom.cardsGrid.classList.add(`size-${size}`);
    dom.cardSizeButtons.forEach((button) => {
      button.classList.toggle("active", button.dataset.size === size);
    });
  }

  function renderSettingsPath() {
    dom.settingsRootPath.textContent = state.lib_root || "Папка не выбрана";
    dom.settingsHeavyThreshold.value = String(state.heavy_faces_threshold || 200000);
  }

  function renderStatus() {
    const text = String(state.status_text || "").trim();
    if (!text) {
      dom.statusLine.hidden = true;
      dom.statusLine.textContent = "";
      if (dom.refreshStatus) {
        dom.refreshStatus.hidden = true;
        dom.refreshStatus.textContent = "";
      }
      return;
    }
    dom.statusLine.hidden = false;
    dom.statusLine.textContent = text;
    if (dom.refreshStatus) {
      dom.refreshStatus.hidden = false;
      dom.refreshStatus.textContent = text;
    }
  }

  function renderArrayPickBanner() {
    if (!dom.arrayPickBanner) return;
    if (state.array_tool_active && !state.array_pick_mode) {
      dom.arrayPickBanner.hidden = false;
      dom.arrayPickBanner.textContent = "Раскладка активна. Для обычной вставки завершите инструмент (Enter/Esc).";
      return;
    }
    if (!state.array_pick_mode) {
      dom.arrayPickBanner.hidden = true;
      dom.arrayPickBanner.textContent = "";
      return;
    }
    dom.arrayPickBanner.hidden = false;
    dom.arrayPickBanner.textContent = String(state.array_pick_message || "Выберите элемент для раскладки");
  }

  function renderWeightFilter() {
    dom.weightFilter.value = state.weight_filter || "all";
  }

  function renderFilterButtons() {
    dom.filterButtons.forEach((button) => {
      button.classList.toggle("active", state.scope === (button.dataset.filter || ""));
    });
  }

  function renderModelRefreshButton() {
    if (!dom.refreshInModelBtn) return;
    dom.refreshInModelBtn.hidden = state.scope !== "in_model";
  }

  function renderPinnedTabs() {
    dom.pinnedTabs.innerHTML = "";
    if (!Array.isArray(state.pinned_categories) || state.pinned_categories.length === 0) return;

    state.pinned_categories.forEach((category) => {
      const button = document.createElement("button");
      button.className = "pinned-tab-btn";
      button.textContent = category;
      button.classList.toggle("active", state.scope === `category:${category}`);
      button.title = "Быстрый переход к категории";
      button.addEventListener("click", () => {
        state.scope = `category:${category}`;
        state.current_page = 1;
        render();
      });
      dom.pinnedTabs.appendChild(button);
    });
  }

  function renderCategoryList() {
    dom.categoryList.innerHTML = "";
    state.categories.forEach((category) => {
      const row = document.createElement("button");
      row.className = "category-btn";
      row.textContent = category;
      row.classList.toggle("active", state.scope === `category:${category}`);
      row.addEventListener("click", () => {
        state.scope = `category:${category}`;
        state.current_page = 1;
        render();
      });
      row.addEventListener("contextmenu", (event) => {
        event.preventDefault();
        showCategoryContextMenu(category, event.clientX, event.clientY);
      });
      dom.categoryList.appendChild(row);
    });
  }

  function renderCardsWithPagination() {
    const filtered = filteredItems();
    normalizeSelection(filtered);

    const totalItems = filtered.length;
    if (state.focus_item_id) {
      const focusIndex = filtered.findIndex((item) => item.id === state.focus_item_id);
      if (focusIndex >= 0) state.current_page = Math.floor(focusIndex / state.page_size) + 1;
    }

    const totalPages = Math.max(1, Math.ceil(totalItems / state.page_size));
    if (state.current_page > totalPages) state.current_page = totalPages;
    if (state.current_page < 1) state.current_page = 1;

    const from = (state.current_page - 1) * state.page_size;
    const pageItems = filtered.slice(from, from + state.page_size);

    renderCards(pageItems);
    renderPagination(totalItems, totalPages, from);
  }

  function filteredItems() {
    let items = [];

    if (state.scope === "in_model") {
      items = Array.isArray(state.in_model_items) ? [...state.in_model_items] : [];
      items.sort((a, b) => (b.instances_count || 0) - (a.instances_count || 0));
    } else {
      items = Array.isArray(state.items) ? [...state.items] : [];

      if (state.scope === "favorites") {
        items = items.filter((item) => !!item.favorite);
      } else if (state.scope === "recent") {
        items = items
          .filter((item) => item.last_used_at)
          .sort((a, b) => String(b.last_used_at).localeCompare(String(a.last_used_at)))
          .slice(0, state.recent_limit || 50);
      } else if (state.scope.startsWith("category:")) {
        const category = state.scope.replace("category:", "");
        items = items.filter((item) => item.category === category);
      } else {
        items = items.sort((a, b) => String(a.name || "").localeCompare(String(b.name || "")));
      }

      if (state.weight_filter !== "all") {
        items = items.filter((item) => {
          const heavy = isHeavyItem(item);
          return state.weight_filter === "heavy" ? heavy : !heavy;
        });
      }
    }

    const query = parseSearch(state.search);
    if (query.words.length || query.tags.length) items = items.filter((item) => matchesQuery(item, query));

    return items;
  }
  function parseSearch(raw) {
    const text = String(raw || "").toLowerCase().trim();
    if (!text) return { words: [], tags: [] };

    const words = [];
    const tags = [];

    text
      .split(/\s+/)
      .map((token) => token.trim())
      .filter(Boolean)
      .forEach((token) => {
        if (token.startsWith("#") && token.length > 1) {
          tags.push(normalizeTag(token.slice(1)));
        } else {
          words.push(token);
        }
      });

    return { words: words.filter(Boolean), tags: tags.filter(Boolean) };
  }

  function matchesQuery(item, query) {
    const tags = normalizeTags(item.tags || []);

    if (query.tags.length > 0 && !query.tags.every((tag) => tags.includes(tag))) return false;
    if (query.words.length === 0) return true;

    const haystack = [item.name || "", item.category || "", item.description || "", tags.join(" ")].join(" ").toLowerCase();
    return query.words.every((token) => haystack.includes(token));
  }

  function renderCards(items) {
    dom.cardsGrid.innerHTML = "";

    items.forEach((item) => {
      const fragment = dom.cardTemplate.content.cloneNode(true);
      const card = fragment.querySelector(".card");
      const favoriteBtn = fragment.querySelector(".card-favorite");
      const deleteBtn = fragment.querySelector(".card-delete");
      const thumb = fragment.querySelector(".thumb");
      const name = fragment.querySelector(".name");
      const meta = fragment.querySelector(".meta");
      const tagsWrap = fragment.querySelector(".tags");

      card.dataset.id = item.id || item.definition_guid || "";
      card.dataset.kind = item.kind || "library";
      card.classList.toggle("selected", isSelected(item));

      name.textContent = item.name || "Без имени";

      if (item.kind === "in_model") {
        meta.textContent = `В модели: ${item.instances_count || 0}`;
        favoriteBtn.hidden = true;
        deleteBtn.hidden = true;
      } else {
        meta.textContent = item.category || "Без категории";
        favoriteBtn.classList.toggle("active", !!item.favorite);
        favoriteBtn.addEventListener("click", (event) => {
          event.stopPropagation();
          ruby("toggle_favorite", { id: item.id, value: !item.favorite });
        });
        deleteBtn.addEventListener("click", (event) => {
          event.stopPropagation();
          ruby("delete_item", item.id);
        });
      }

      const placeholder = placeholderThumb(item.name || "Компонент");
      thumb.src = item.thumb_url || placeholder;
      thumb.alt = item.thumb_url ? "Превью" : "Нет превью";
      thumb.onerror = () => {
        thumb.src = placeholder;
      };

      renderCardTags(tagsWrap, item);
      renderPlacementBadge(tagsWrap, item);

      card.addEventListener("click", () => {
        if (state.array_pick_mode && item.kind === "library") {
          ruby("array_pick_from_library", item.id);
          return;
        }
        selectItem(item);
      });
      card.addEventListener("dblclick", (event) => {
        event.preventDefault();
        event.stopPropagation();
        if (state.array_pick_mode && item.kind === "library") {
          ruby("array_pick_from_library", item.id);
          return;
        }
        if (state.array_tool_active) return;
        if (item.kind === "library") ruby("insert_item", item.id);
      });
      card.addEventListener("contextmenu", (event) => {
        event.preventDefault();
        if (state.array_pick_mode || state.array_tool_active) return;
        showCardContextMenu(item, event.clientX, event.clientY);
      });

      dom.cardsGrid.appendChild(fragment);
    });

    if (state.focus_item_id) {
      const focused = dom.cardsGrid.querySelector(".card.selected");
      if (focused) focused.scrollIntoView({ block: "nearest", inline: "nearest" });
      state.focus_item_id = null;
    }
  }

  function renderCardTags(wrapper, item) {
    wrapper.innerHTML = "";

    const tags = normalizeTags(item.tags || []);
    if (tags.length === 0) {
      const empty = document.createElement("span");
      empty.className = "tag tag-empty";
      empty.textContent = "без тегов";
      wrapper.appendChild(empty);
      return;
    }

    tags.slice(0, 3).forEach((tag) => {
      const chip = document.createElement("span");
      chip.className = "tag tag-clickable";
      chip.textContent = tag;
      chip.title = "Фильтр по тегу";
      chip.addEventListener("click", (event) => {
        event.stopPropagation();
        applyTagToSearch(tag);
      });
      wrapper.appendChild(chip);
    });

    if (tags.length > 3) {
      const more = document.createElement("span");
      more.className = "tag";
      more.textContent = `+${tags.length - 3}`;
      wrapper.appendChild(more);
    }
  }

  function renderPlacementBadge(wrapper, item) {
    if (!wrapper || !item || item.kind === "in_model") return;
    const placement = normalizePlacement(item.placement);
    const short = placementShortLabel(placement.type);
    if (!short) return;

    const badge = document.createElement("span");
    badge.className = "tag tag-placement";
    badge.textContent = short;
    badge.title = "Паспорт размещения";
    wrapper.appendChild(badge);
  }

  function applyTagToSearch(tag) {
    const normalized = normalizeTag(tag);
    if (!normalized) return;

    const parsed = parseSearch(state.search);
    if (!parsed.tags.includes(normalized)) parsed.tags.push(normalized);

    const next = [...parsed.words, ...parsed.tags.map((value) => `#${value}`)].join(" ");

    state.search = next;
    dom.search.value = next;
    state.current_page = 1;
    renderCardsWithPagination();
  }

  function renderPagination(totalItems, totalPages, fromIndex) {
    dom.pageSizeButtons.forEach((button) => {
      const size = Number(button.dataset.pageSize || 25);
      button.classList.toggle("active", size === state.page_size);
    });

    dom.pagePrev.disabled = state.current_page <= 1;
    dom.pageNext.disabled = state.current_page >= totalPages;

    const firstItem = totalItems === 0 ? 0 : fromIndex + 1;
    const lastItem = Math.min(totalItems, fromIndex + state.page_size);
    dom.pageInfo.textContent = `Показано ${firstItem}-${lastItem} из ${totalItems}`;

    dom.pageNumbers.innerHTML = "";
    visiblePages(totalPages, state.current_page).forEach((page) => {
      if (page === "...") {
        const dots = document.createElement("span");
        dots.className = "page-dots";
        dots.textContent = "...";
        dom.pageNumbers.appendChild(dots);
        return;
      }

      const button = document.createElement("button");
      button.className = "page-num-btn";
      button.textContent = String(page);
      button.classList.toggle("active", page === state.current_page);
      button.addEventListener("click", () => {
        state.current_page = page;
        renderCardsWithPagination();
      });
      dom.pageNumbers.appendChild(button);
    });
  }

  function visiblePages(totalPages, currentPage) {
    if (totalPages <= 7) return Array.from({ length: totalPages }, (_, index) => index + 1);

    const pages = [1];
    const start = Math.max(2, currentPage - 1);
    const finish = Math.min(totalPages - 1, currentPage + 1);

    if (start > 2) pages.push("...");
    for (let page = start; page <= finish; page += 1) pages.push(page);
    if (finish < totalPages - 1) pages.push("...");
    pages.push(totalPages);

    return pages;
  }
  function renderInspector() {
    const selected = selectedItem();

    dom.inspectorEmpty.hidden = !!selected;
    dom.inspectorLibrary.hidden = !selected || selected.kind !== "library";
    dom.inspectorModel.hidden = !selected || selected.kind !== "in_model";
    dom.inspectorInsertOptions.hidden = !selected || selected.kind !== "library";

    if (!selected) {
      dom.inspectorTitle.textContent = "Инспектор";
      return;
    }

    if (state.inspector_collapsed) {
      state.inspector_collapsed = false;
      renderInspectorCollapsedState();
    }

    if (selected.kind === "library") {
      renderInspectorLibrary(selected);
    } else {
      renderInspectorModel(selected);
    }
  }

  function renderInspectorLibrary(item) {
    dom.inspectorTitle.textContent = item.name || "Инспектор";

    const previewSrc = item.thumb_url || placeholderThumb(item.name || "Компонент");
    dom.inspectorPreview.src = previewSrc;
    dom.inspectorPreview.alt = item.thumb_url ? "Превью" : "Нет превью";

    setControlValue(dom.inspectorName, item.name || "");
    setControlValue(dom.inspectorDescription, item.description || "");

    populateInspectorCategory(item.category);
    populateInspectorTagSuggestions();
    renderInspectorTags(item.tags || []);
    renderQuickTagSuggestions(dom.inspectorTagInput.value);
    renderPlacementEditor(item);

    dom.inspectorToggleFavorite.textContent = item.favorite ? "★ Убрать из избранного" : "★ В избранное";
    if (dom.inspectorReplaceFromSelection) {
      dom.inspectorReplaceFromSelection.disabled = false;
      dom.inspectorReplaceFromSelection.removeAttribute("disabled");
      const allowed = canReplaceLibraryItemFromSelection(item);
      dom.inspectorReplaceFromSelection.classList.toggle("ui-disabled", !allowed);
      dom.inspectorReplaceFromSelection.title = allowed
        ? ""
        : "Выберите в модели ровно один объект типа Группа или Компонент";
    }
  }

  function renderInspectorModel(item) {
    dom.inspectorTitle.textContent = item.name || "В модели";
    dom.modelName.textContent = item.name || "Без имени";
    dom.modelCount.textContent = String(item.instances_count || 0);
  }

  function setControlValue(control, value) {
    if (document.activeElement === control) return;
    control.value = String(value || "");
  }

  function populateInspectorCategory(selectedCategory) {
    const current = String(selectedCategory || "");
    const values = [...state.categories];
    if (current && !values.includes(current)) values.push(current);

    dom.inspectorCategory.innerHTML = "";
    values.sort((a, b) => a.localeCompare(b, "ru"));

    values.forEach((category) => {
      const option = document.createElement("option");
      option.value = category;
      option.textContent = category;
      dom.inspectorCategory.appendChild(option);
    });

    if (state.pending_select_category && values.includes(state.pending_select_category)) {
      dom.inspectorCategory.value = state.pending_select_category;
      state.pending_select_category = null;
      return;
    }

    dom.inspectorCategory.value = current;
  }

  function populateInspectorTagSuggestions() {
    dom.inspectorTagSuggestions.innerHTML = "";
    state.all_tags.forEach((tag) => {
      const option = document.createElement("option");
      option.value = tag;
      dom.inspectorTagSuggestions.appendChild(option);
    });
  }

  function renderInspectorTags(tags) {
    dom.inspectorTags.innerHTML = "";
    normalizeTags(tags).forEach((tag) => {
      const chip = document.createElement("button");
      chip.type = "button";
      chip.className = "inspector-tag-chip";
      chip.textContent = `${tag} ×`;
      chip.addEventListener("click", () => removeInspectorTag(tag));
      dom.inspectorTags.appendChild(chip);
    });
    renderQuickTagSuggestions(dom.inspectorTagInput.value);
  }

  function renderQuickTagSuggestions(rawInput) {
    if (!dom.inspectorTagQuick) return;

    const selected = selectedItem();
    if (!selected || selected.kind !== "library") {
      dom.inspectorTagQuick.innerHTML = "";
      return;
    }

    const input = normalizeTag(rawInput || "");
    const currentTags = normalizeTags(selected.tags || []);
    let candidates = normalizeTags(state.all_tags || []).filter((tag) => !currentTags.includes(tag));

    if (input) {
      candidates = candidates.filter((tag) => tag.includes(input));
    }

    candidates = candidates.slice(0, 10);
    dom.inspectorTagQuick.innerHTML = "";

    if (candidates.length === 0) return;

    candidates.forEach((tag) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "tag-quick-item";
      button.textContent = tag;
      button.title = "Добавить тег";
      button.addEventListener("mousedown", (event) => {
        event.preventDefault();
      });
      button.addEventListener("click", () => {
        addInspectorTag(tag);
      });
      dom.inspectorTagQuick.appendChild(button);
    });
  }

  function selectedItem() {
    if (!state.selected_ref) return null;
    if (state.selected_ref.kind === "library") {
      return state.items.find((item) => item.id === state.selected_ref.id) || null;
    }
    if (state.selected_ref.kind === "in_model") {
      return state.in_model_items.find((item) => item.definition_guid === state.selected_ref.definition_guid) || null;
    }
    return null;
  }

  function selectItem(item) {
    if (!item) return;
    const prev = state.selected_ref;

    if (item.kind === "in_model") {
      state.selected_ref = { kind: "in_model", definition_guid: item.definition_guid };
      ruby("select_item", { id: item.definition_guid, source: "model" });
    } else {
      state.selected_ref = { kind: "library", id: item.id };
      ruby("select_item", { id: item.id, source: "library" });

      const changedLibraryItem =
        !prev ||
        prev.kind !== "library" ||
        prev.id !== item.id;
      if (changedLibraryItem) {
        const defaults = defaultInsertOptions();
        state.insert_options = defaults;
        renderInsertOptions();
        ruby("set_insert_options", defaults);
      }
    }

    state.inspector_collapsed = false;
    renderCardsWithPagination();
    renderInspector();
    renderInspectorCollapsedState();
  }

  function isSelected(item) {
    if (!item || !state.selected_ref) return false;
    if (item.kind === "in_model") {
      return state.selected_ref.kind === "in_model" && state.selected_ref.definition_guid === item.definition_guid;
    }
    return state.selected_ref.kind === "library" && state.selected_ref.id === item.id;
  }

  function normalizeSelection(filteredItemsList) {
    if (!state.selected_ref) {
      if (state.focus_item_id) state.selected_ref = { kind: "library", id: String(state.focus_item_id) };
      return;
    }

    const selected = selectedItem();
    if (selected) return;

    const existsInFiltered = filteredItemsList.some((item) => isSelected(item));
    if (!existsInFiltered) state.selected_ref = null;
  }

  function itemByCard(card) {
    if (!card) return null;
    const kind = card.dataset.kind || "library";
    const id = card.dataset.id || "";

    if (kind === "in_model") {
      return state.in_model_items.find((item) => item.definition_guid === id) || null;
    }

    return state.items.find((item) => item.id === id) || null;
  }

  function isHeavyItem(item) {
    const threshold = Number(state.heavy_faces_threshold || 200000);
    const faces = Number(item.faces_count || 0);
    const fileSize = Number(item.file_size_bytes || 0);
    if (faces > 0) return faces >= threshold;
    return fileSize >= 15 * 1024 * 1024;
  }

  function normalizeTag(value) {
    return String(value || "").trim().toLowerCase();
  }

  function normalizeTags(values) {
    const source = Array.isArray(values) ? values : String(values || "").split(",");
    const unique = [];

    source.forEach((entry) => {
      const normalized = normalizeTag(entry);
      if (!normalized) return;
      if (!unique.includes(normalized)) unique.push(normalized);
    });

    unique.sort();
    return unique;
  }
  function placeholderThumb(label) {
    const text = (label || "Компонент").slice(0, 16);
    const svg = `<svg xmlns='http://www.w3.org/2000/svg' width='400' height='300'><defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'><stop offset='0%' stop-color='#f6fbff'/><stop offset='100%' stop-color='#e4edf7'/></linearGradient></defs><rect width='100%' height='100%' fill='url(#g)'/><rect x='95' y='55' width='210' height='160' rx='12' fill='#dce8f4' stroke='#9db6cd' stroke-width='4'/><text x='200' y='260' font-family='Segoe UI, Arial' font-size='18' fill='#4e6881' text-anchor='middle'>${escapeXml(text)}</text></svg>`;
    return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`;
  }

  function escapeXml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&apos;");
  }

  function showCardContextMenu(item, x, y) {
    if (!dom.cardContextMenu) return;
    state.context_item = item;

    const isLibrary = item && item.kind === "library";
    Array.from(dom.cardContextMenu.querySelectorAll("button")).forEach((button) => {
      const action = button.dataset.action;
      const onlyLibrary = ["insert", "brush", "replace_from_selection", "show_file", "open_folder", "regen_preview", "copy_path", "delete"].includes(action);
      button.hidden = !!onlyLibrary && !isLibrary;
      button.disabled = false;
      button.removeAttribute("disabled");
      if (action === "replace_from_selection") {
        const allowed = canReplaceLibraryItemFromSelection(item);
        button.classList.toggle("ui-disabled", !allowed);
        button.title = allowed
          ? ""
          : "Выберите в модели ровно один объект типа Группа или Компонент";
      } else {
        button.classList.remove("ui-disabled");
        button.title = "";
      }
    });

    dom.cardContextMenu.hidden = false;
    dom.cardContextMenu.style.left = `${x}px`;
    dom.cardContextMenu.style.top = `${y}px`;
  }

  function hideCardContextMenu() {
    state.context_item = null;
    if (!dom.cardContextMenu) return;
    dom.cardContextMenu.hidden = true;
  }

  function onCardContextMenuClick(event) {
    if (state.array_pick_mode || state.array_tool_active) return;

    const button = event.target.closest("button[data-action]");
    if (!button || !state.context_item) return;

    const action = button.dataset.action;
    const item = state.context_item;
    hideCardContextMenu();

    if (action === "insert" && item.kind === "library") return ruby("insert_item", item.id);
    if (action === "brush" && item.kind === "library") return ruby("start_brush", item.id);
    if (action === "replace") {
      if (item.kind === "library") return ruby("replace_selection", item.id);
      return ruby("replace_selection_model", item.definition_guid);
    }
    if (action === "replace_from_selection" && item.kind === "library") {
      const called = ruby("replace_library_item_from_selection", { id: item.id });
      if (!called) {
        alert("Команда недоступна: callback не найден. Сделайте полный reload плагина.");
      }
      return called;
    }
    if (action === "show_file" && item.kind === "library") return ruby("show_in_folder", item.id);
    if (action === "open_folder" && item.kind === "library") return ruby("open_folder", item.id);
    if (action === "regen_preview" && item.kind === "library") return ruby("regenerate_thumbnail", item.id);
    if (action === "copy_path") return copyText(item.skp_full_path || "");
    if (action === "copy_name") return copyText(item.name || "");
    if (action === "delete" && item.kind === "library") return ruby("delete_item", item.id);
    return null;
  }

  function showCategoryContextMenu(category, x, y) {
    if (!dom.categoryContextMenu) return;
    state.context_category = category;

    const pinned = state.pinned_categories.includes(category);
    const toggleBtn = dom.categoryContextMenu.querySelector("button[data-action='toggle_pin']");
    if (toggleBtn) toggleBtn.textContent = pinned ? "Открепить" : "Закрепить";

    dom.categoryContextMenu.hidden = false;
    dom.categoryContextMenu.style.left = `${x}px`;
    dom.categoryContextMenu.style.top = `${y}px`;
  }

  function hideCategoryContextMenu() {
    state.context_category = null;
    if (!dom.categoryContextMenu) return;
    dom.categoryContextMenu.hidden = true;
  }

  function onCategoryContextMenuClick(event) {
    const button = event.target.closest("button[data-action]");
    if (!button || !state.context_category) return;

    const action = button.dataset.action;
    const category = state.context_category;
    hideCategoryContextMenu();

    if (action === "toggle_pin") ruby("toggle_pinned_category", { category });
  }

  function copyText(value) {
    const text = String(value || "");
    if (!text) return;

    if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
      navigator.clipboard.writeText(text).catch(() => prompt("Скопируйте значение:", text));
      return;
    }

    prompt("Скопируйте значение:", text);
  }

  function applyIncomingState(nextState) {
    state.lib_root = nextState && nextState.lib_root ? nextState.lib_root : "";
    state.categories = nextState && Array.isArray(nextState.categories) ? nextState.categories : [];
    state.pinned_categories = nextState && Array.isArray(nextState.pinned_categories) ? nextState.pinned_categories : [];
    state.items = nextState && Array.isArray(nextState.items) ? nextState.items : [];
    state.in_model_items = nextState && Array.isArray(nextState.in_model_items) ? nextState.in_model_items : [];
    state.all_tags = nextState && Array.isArray(nextState.all_tags) ? nextState.all_tags : [];
    state.recent_limit = nextState && nextState.recent_limit ? nextState.recent_limit : 50;
    state.insert_options = nextState && nextState.insert_options ? nextState.insert_options : state.insert_options;
    state.status_text = nextState && typeof nextState.status_text === "string" ? nextState.status_text : "";
    state.heavy_faces_threshold =
      nextState && Number(nextState.heavy_faces_threshold || 0) > 0
        ? Number(nextState.heavy_faces_threshold)
        : state.heavy_faces_threshold;
    state.focus_item_id = nextState && nextState.focus_item_id ? String(nextState.focus_item_id) : null;
    state.array_pick_mode = !!(nextState && nextState.array_pick_mode);
    state.array_tool_active = !!(nextState && nextState.array_tool_active);
    state.array_pick_message =
      nextState && typeof nextState.array_pick_message === "string"
        ? nextState.array_pick_message
        : "";
    applySelectionState(nextState ? nextState.selection_state : null);

    if (state.focus_item_id) {
      const focusItem = state.items.find((item) => item.id === state.focus_item_id);
      if (focusItem) {
        state.selected_ref = { kind: "library", id: focusItem.id };
      }
    }

    const categoryScope = state.scope.startsWith("category:") ? state.scope.replace("category:", "") : "";
    if (categoryScope && !state.categories.includes(categoryScope)) state.scope = "all";

    renderInsertOptions();
    render();
  }

  function applySelectionState(nextSelectionState) {
    const raw = nextSelectionState || {};
    state.selection_state = {
      count: Number(raw.count || 0),
      replace_library_from_selection_allowed: !!raw.replace_library_from_selection_allowed,
    };
  }

  function canReplaceLibraryItemFromSelection(item) {
    return !!(item && item.kind === "library" && state.selection_state.replace_library_from_selection_allowed);
  }

  function renderInsertOptions() {
    const options = state.insert_options || {};
    renderInsertOptionButton(dom.optionSurface, !!options.place_on_surface);
    renderInsertOptionButton(dom.optionNormal, !!options.align_to_normal);
    renderInsertOptionButton(dom.optionRandom, !!options.random_quadrant);
    renderInsertOptionButton(dom.optionGround, !!options.drop_to_ground);
    if (dom.optionRandomStep) {
      const step = Number(options.random_step_degrees || 90);
      dom.optionRandomStep.value = String(step);
      dom.optionRandomStep.disabled = !options.random_quadrant;
    }
  }

  function renderInsertOptionButton(button, active) {
    if (!button) return;
    button.checked = !!active;
    const row = button.closest(".insert-opt-check");
    if (row) row.classList.toggle("active", !!active);
  }

  function defaultInsertOptions() {
    return {
      place_on_surface: true,
      align_to_normal: false,
      random_quadrant: false,
      drop_to_ground: false,
      random_step_degrees: 90,
    };
  }

  window.ComponentLibrary = {
    setState(nextState) {
      applyIncomingState(nextState || {});
    },
    setStatus(text) {
      state.status_text = String(text || "");
      renderStatus();
    },
    setSelectionState(nextSelectionState) {
      applySelectionState(nextSelectionState || {});
      renderInspector();
    },
  };

  document.addEventListener("DOMContentLoaded", init);
})();
