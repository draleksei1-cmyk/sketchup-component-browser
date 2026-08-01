(function () {
  "use strict";

  // The harness sets this flag before loading this file. It prevents production polling.
  const TEST_BOOTSTRAP = !!window.__CLB_TEST_BOOTSTRAP__;
  const state = { items: [], in_model_items: [], categories: [], all_tags: [], scope: "all", search: "", card_size: "medium", selected: null, contextItem: null, lastFocus: null, insert_options: {}, array_pick_mode: false, array_pick_message: "", selection_state: {} };
  const dom = {};
  const FALLBACKS = { start_brush: ["start_brush_item"], replace_selection: ["replace_with_library_item"], regenerate_thumbnail: ["regenerate_preview_item"], open_folder: ["item_open_folder"], show_in_folder: ["item_reveal_file"], update_item_fields: ["edit_item"], modeltab_save_to_library: ["save_in_model_definition"], modeltab_select_all: ["select_all_in_model"], replace_selection_model: ["replace_with_model_definition"] };

  function ruby(name, payload) {
    if (!window.sketchup) return false;
    return [name].concat(FALLBACKS[name] || []).some(function (callback) {
      if (typeof window.sketchup[callback] !== "function") return false;
      window.sketchup[callback](payload === undefined ? undefined : typeof payload === "string" ? payload : JSON.stringify(payload));
      return true;
    });
  }

  function iconName() { return ""; }
  function cache() {
    ["search","refresh-btn","library-overflow","library-overflow-menu","cards-grid","card-template","details-drawer","drawer-title","drawer-preview","drawer-favorite","drawer-close","primary-insert","primary-insert-label","drawer-brush","drawer-replace","drawer-replace-from-selection","drawer-model-select-all","drawer-regen","drawer-show-file","drawer-open-folder","drawer-name","drawer-category","drawer-description","drawer-tags","category-list","category-context-menu","save-selected-btn","settings-btn","status-line","array-pick-banner","card-context-menu","context-select-all-model","settings-backdrop","settings-close","settings-root-path","settings-heavy-threshold","settings-save-threshold","settings-change-root","settings-scan","settings-regen-all","empty-state","opt-surface","opt-normal","opt-random","opt-ground"].forEach(function (id) { dom[id] = document.getElementById(id); });
    dom.filterButtons = Array.prototype.slice.call(document.querySelectorAll(".filter-btn"));
    dom.sizeButtons = Array.prototype.slice.call(document.querySelectorAll(".size-btn"));
  }

  function init() {
    cache();
    bind();
    render();
    ruby("ready");
    ruby("refresh_selection_state");
    if (!TEST_BOOTSTRAP) window.setInterval(function () { ruby("refresh_selection_state"); }, 1200);
  }

  function bind() {
    dom["search"].addEventListener("input", function () { state.search = this.value || ""; renderCards(); });
    dom["refresh-btn"].addEventListener("click", function () { ruby("refresh_index_only"); });
    dom.filterButtons.forEach(function (button) { button.addEventListener("click", function () { state.scope = button.dataset.filter; if (state.scope === "in_model") ruby("refresh_in_model"); render(); }); });
    dom.sizeButtons.forEach(function (button) { button.addEventListener("click", function () { state.card_size = button.dataset.size; renderCards(); }); });
    dom["library-overflow"].addEventListener("click", function () { toggleMenu(dom["library-overflow-menu"], dom["library-overflow"]); });
    dom["library-overflow-menu"].addEventListener("click", onOverflowCommand);
    dom["drawer-close"].addEventListener("click", closeDrawer);
    dom["drawer-favorite"].addEventListener("click", function () { const item = selected(); if (item && item.kind !== "in_model") ruby("toggle_favorite", { id: item.id, value: !item.favorite }); });
    dom["primary-insert"].addEventListener("click", function () { const item = selected(); if (!item) return; if (item.kind === "in_model") ruby("modeltab_save_to_library", { definition_guid: item.definition_guid }); else ruby("insert_item", item.id); });
    dom["drawer-brush"].addEventListener("click", function () { const item = selected(); if (item && item.kind !== "in_model") ruby("start_brush", item.id); });
    dom["drawer-replace"].addEventListener("click", function () { const item = selected(); if (!item) return; if (item.kind === "in_model") ruby("replace_selection_model", item.definition_guid); else ruby("replace_selection", item.id); });
    dom["drawer-replace-from-selection"].addEventListener("click", function () { const item = selected(); if (item && item.kind !== "in_model") ruby("replace_library_item_from_selection", { id: item.id }); });
    dom["drawer-regen"].addEventListener("click", function () { const item = selected(); if (item && item.kind !== "in_model") ruby("regenerate_thumbnail", item.id); });
    dom["drawer-show-file"].addEventListener("click", function () { const item = selected(); if (item && item.kind !== "in_model") ruby("show_in_folder", item.id); });
    dom["drawer-open-folder"].addEventListener("click", function () { const item = selected(); if (item && item.kind !== "in_model") ruby("open_folder", item.id); });
    dom["drawer-model-select-all"].addEventListener("click", function () { const item = selected(); if (item && item.kind === "in_model") ruby("modeltab_select_all", item.definition_guid); });
    ["drawer-name","drawer-category","drawer-description","drawer-tags"].forEach(function (id) { dom[id].addEventListener("change", saveFields); dom[id].addEventListener("blur", saveFields); });
    ["opt-surface","opt-normal","opt-random","opt-ground"].forEach(function (id) { dom[id].addEventListener("change", function () { ruby("set_insert_option", { key: this.dataset.insertOpt, value: this.checked }); }); });
    dom["category-list"].addEventListener("click", function (event) { const button = event.target.closest("button[data-category]"); if (button) { state.scope = "category:" + button.dataset.category; render(); } });
    dom["category-list"].addEventListener("contextmenu", function (event) { const button = event.target.closest("button[data-category]"); if (!button) return; event.preventDefault(); state.contextCategory = button.dataset.category; state.lastFocus = button; openCategoryContext(event.clientX, event.clientY); });
    document.getElementById("category-add").addEventListener("click", function () { const name = window.prompt("Имя новой категории:"); if (name) ruby("category_add", name); });
    dom["save-selected-btn"].addEventListener("click", function () { ruby("save_selected", {}); });
    dom["settings-btn"].addEventListener("click", openSettings);
    dom["settings-close"].addEventListener("click", closeSettings);
    dom["settings-backdrop"].addEventListener("click", function (event) { if (event.target === dom["settings-backdrop"]) closeSettings(); });
    dom["settings-save-threshold"].addEventListener("click", function () { ruby("set_heavy_threshold", { value: Number(dom["settings-heavy-threshold"].value) }); });
    dom["settings-change-root"].addEventListener("click", function () { ruby("open_settings"); });
    dom["settings-scan"].addEventListener("click", function () { ruby("scan_library"); });
    dom["settings-regen-all"].addEventListener("click", function () { ruby("regenerate_previews_all"); });
    dom["card-context-menu"].addEventListener("click", onContextCommand);
    dom["category-context-menu"].addEventListener("click", onCategoryContextCommand);
    document.addEventListener("click", function (event) { if (!event.target.closest(".menu-wrap")) closeMenu(dom["library-overflow-menu"], dom["library-overflow"]); if (!event.target.closest("#card-context-menu")) closeContext(); if (!event.target.closest("#category-context-menu")) closeCategoryContext(); });
    document.addEventListener("keydown", function (event) { if (event.key === "Escape") { if (!dom["settings-backdrop"].hidden) closeSettings(); else if (!dom["card-context-menu"].hidden) closeContext(); else if (!dom["category-context-menu"].hidden) closeCategoryContext(); else if (!dom["library-overflow-menu"].hidden) closeMenu(dom["library-overflow-menu"], dom["library-overflow"]); else closeDrawer(); } });
  }

  function selected() { return state.items.concat(state.in_model_items).find(function (item) { return item.id === state.selected || item.definition_guid === state.selected; }); }
  function itemsForScope() {
    let list = state.scope === "in_model" ? state.in_model_items : state.items;
    if (state.scope === "favorites") list = state.items.filter(function (item) { return item.favorite; });
    if (state.scope === "recent") list = state.items.slice().sort(function (a,b) { return String(b.updated_at || "").localeCompare(String(a.updated_at || "")); });
    if (state.scope.indexOf("category:") === 0) list = state.items.filter(function (item) { return item.category === state.scope.slice(9); });
    const query = state.search.trim().toLowerCase();
    return query ? list.filter(function (item) { return [item.name,item.category].concat(item.tags || []).join(" ").toLowerCase().indexOf(query) !== -1; }) : list;
  }
  function render() { renderFilters(); renderCategories(); renderCards(); renderStatus(); renderDrawer(); }
  function renderFilters() { dom.filterButtons.forEach(function (button) { button.classList.toggle("active", button.dataset.filter === state.scope); }); }
  function renderCategories() { dom["category-list"].innerHTML = ""; state.categories.forEach(function (category) { const button = document.createElement("button"); button.type = "button"; button.className = "category-btn" + (state.scope === "category:" + category ? " active" : ""); button.dataset.category = category; button.textContent = category; dom["category-list"].appendChild(button); }); }
  function renderCards() {
    const list = itemsForScope(); dom["cards-grid"].className = "cards-grid size-" + state.card_size; dom["cards-grid"].innerHTML = ""; dom["empty-state"].hidden = list.length > 0;
    list.forEach(function (item) { const node = dom["card-template"].content.firstElementChild.cloneNode(true); node.dataset.id = item.id || item.definition_guid; node.classList.toggle("selected", state.selected === node.dataset.id); node.querySelector(".name").textContent = item.name || "Без имени"; node.querySelector(".meta").textContent = item.category || "Без категории"; const img = node.querySelector(".thumb"); img.src = item.thumb_url || ""; img.hidden = !item.thumb_url; (item.tags || []).slice(0,2).forEach(function (tag) { const chip=document.createElement("span"); chip.className="tag"; chip.textContent=tag; node.querySelector(".tags").appendChild(chip); }); node.addEventListener("click", function () { state.selected = node.dataset.id; state.lastFocus = node; ruby("select_item", { id: node.dataset.id, source: item.kind === "in_model" ? "model" : "library" }); dom["cards-grid"].querySelectorAll(".library-card.selected").forEach(function (card) { card.classList.remove("selected"); }); node.classList.add("selected"); openDrawer(); }); node.addEventListener("dblclick", function () { if (state.array_pick_mode && item.kind === "library") ruby("array_pick_from_library", item.id); else if (item.kind === "library") ruby("insert_item", item.id); }); node.addEventListener("contextmenu", function (event) { event.preventDefault(); state.contextItem = item; state.lastFocus = node; openContext(event.clientX,event.clientY); }); node.addEventListener("keydown", function (event) { if (event.key === "Enter") { event.preventDefault(); node.click(); } if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) { event.preventDefault(); const rect=node.getBoundingClientRect(); state.contextItem=item; state.lastFocus=node; openContext(rect.left,rect.bottom); } }); dom["cards-grid"].appendChild(node); }); }
  function renderStatus() { const text=state.status_text || ""; dom["status-line"].hidden=!text; dom["status-line"].textContent=text; const pick=state.array_pick_mode; dom["array-pick-banner"].hidden=!pick; dom["array-pick-banner"].textContent=state.array_pick_message || "Выберите компонент библиотеки для массива."; }
  function openDrawer() { dom["details-drawer"].hidden=false; dom["details-drawer"].setAttribute("aria-hidden","false"); renderDrawer(); }
  function closeDrawer() { if (dom["details-drawer"].hidden) return; dom["details-drawer"].hidden=true; dom["details-drawer"].setAttribute("aria-hidden","true"); if (state.lastFocus) state.lastFocus.focus(); }
  function renderDrawer() { const item=selected(); if (!item || dom["details-drawer"].hidden) return; const modelItem=item.kind === "in_model"; dom["primary-insert-label"].textContent=modelItem ? "Сохранить в библиотеку" : "Вставить"; dom["drawer-title"].textContent=item.name || "Без имени"; dom["drawer-preview"].src=item.thumb_url || ""; dom["drawer-name"].value=item.name || ""; dom["drawer-description"].value=item.description || ""; dom["drawer-tags"].value=(item.tags || []).join(", "); dom["drawer-favorite"].hidden=modelItem; dom["drawer-brush"].hidden=modelItem; dom["drawer-replace-from-selection"].hidden=modelItem; dom["drawer-regen"].hidden=modelItem; dom["drawer-show-file"].hidden=modelItem; dom["drawer-open-folder"].hidden=modelItem; dom["drawer-name"].disabled=modelItem; dom["drawer-category"].disabled=modelItem; dom["drawer-description"].disabled=modelItem; dom["drawer-tags"].disabled=modelItem; dom["drawer-favorite"].setAttribute("aria-label", item.favorite ? "Убрать из избранного" : "В избранное"); dom["drawer-model-select-all"].hidden = !modelItem; dom["drawer-category"].innerHTML=""; state.categories.forEach(function (category) { const option=document.createElement("option"); option.value=category; option.textContent=category; option.selected=category===item.category; dom["drawer-category"].appendChild(option); }); ["opt-surface","opt-normal","opt-random","opt-ground"].forEach(function (id) { const key=dom[id].dataset.insertOpt; dom[id].checked=!!state.insert_options[key]; }); }
  function saveFields() { const item=selected(); if (!item || item.kind === "in_model") return; ruby("update_item_fields", { id:item.id, name:dom["drawer-name"].value, category:dom["drawer-category"].value, description:dom["drawer-description"].value, tags:dom["drawer-tags"].value.split(",").map(function(tag){return tag.trim();}).filter(Boolean) }); }
  function toggleMenu(menu, trigger) { const open=menu.hidden; menu.hidden=!open; trigger.setAttribute("aria-expanded",String(open)); if (open) menu.querySelector("button").focus(); }
  function closeMenu(menu, trigger) { if (!menu.hidden) { menu.hidden=true; trigger.setAttribute("aria-expanded","false"); trigger.focus(); } }
  function onOverflowCommand(event) { const action=event.target.dataset.command; if (!action) return; closeMenu(dom["library-overflow-menu"],dom["library-overflow"]); if (action === "weight") { state.scope="all"; render(); return; } if (action === "settings") return openSettings(); ruby(action); }
  function openContext(x,y) { const menu=dom["card-context-menu"]; const modelItem=state.contextItem && state.contextItem.kind === "in_model"; dom["context-select-all-model"].hidden=!modelItem; menu.querySelector("[data-action=delete]").hidden=modelItem; menu.style.left=x+"px"; menu.style.top=y+"px"; menu.hidden=false; menu.querySelector("button:not([hidden])").focus(); }
  function closeContext() { const menu=dom["card-context-menu"]; if (!menu.hidden) { menu.hidden=true; if (state.lastFocus) state.lastFocus.focus(); } }
  function onContextCommand(event) { const action=event.target.dataset.action, item=state.contextItem; if (!action || !item) return; closeContext(); if (item.kind === "in_model") { const modelMap={insert:"modeltab_save_to_library",replace:"replace_selection_model",replace_from_selection:"replace_selection_model",select_all_model:"modeltab_select_all"}; if (modelMap[action]) return ruby(modelMap[action], item.definition_guid); } const map={insert:"insert_item",brush:"start_brush",replace:"replace_selection",replace_from_selection:"replace_library_item_from_selection",regen_preview:"regenerate_thumbnail",show_file:"show_in_folder",open_folder:"open_folder",copy_path:"copy_path",delete:"delete_item"}; if (map[action]) ruby(map[action], action === "replace_from_selection" ? {id:item.id} : item.id); }
  function openCategoryContext(x,y) { const menu=dom["category-context-menu"]; menu.style.left=x+"px"; menu.style.top=y+"px"; menu.hidden=false; menu.querySelector("button").focus(); }
  function closeCategoryContext() { const menu=dom["category-context-menu"]; if (!menu.hidden) { menu.hidden=true; if (state.lastFocus) state.lastFocus.focus(); } }
  function onCategoryContextCommand(event) { const action=event.target.dataset.action, category=state.contextCategory; if (!action || !category) return; closeCategoryContext(); const payload={rename:{old:category,new:window.prompt("Новое имя категории:",category)},delete:category,regenerate:category,pin:{category:category}}[action]; if (action === "rename" && (!payload || !payload.new)) return; const map={rename:"category_rename",delete:"category_delete",regenerate:"regenerate_previews_category",pin:"toggle_pinned_category"}; ruby(map[action], payload); }
  function openSettings() { dom["settings-root-path"].textContent=state.lib_root || "Папка не выбрана"; dom["settings-heavy-threshold"].value=state.heavy_faces_threshold || 200000; dom["settings-backdrop"].hidden=false; dom["settings-close"].focus(); }
  function closeSettings() { dom["settings-backdrop"].hidden=true; dom["settings-btn"].focus(); }
  function setState(next) { Object.assign(state,next || {}); state.items=Array.isArray(state.items)?state.items:[]; state.in_model_items=Array.isArray(state.in_model_items)?state.in_model_items:[]; state.categories=Array.isArray(state.categories)?state.categories:[]; state.insert_options=state.insert_options || {}; render(); }
  window.ComponentLibrary={setState:setState,setStatus:function(text){state.status_text=String(text||"");renderStatus();},setSelectionState:function(selection){state.selection_state=selection||{};renderDrawer();}};
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
}());
