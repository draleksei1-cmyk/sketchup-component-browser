(function () {
  "use strict";
  const callbacks = [];
  window.__CLB_TEST_BOOTSTRAP__ = true;
  window.__clbHarness = { callbacks: callbacks };
  window.sketchup = new Proxy({}, {
    get: function (_target, name) {
      return function (payload) {
        callbacks.push({ name: String(name), payload: payload });
        if (name === "ready" && window.ComponentLibrary) window.ComponentLibrary.setState(window.__clbFixture);
      };
    }
  });
  Promise.all([fetch("fixtures/library-state.json").then(function (response) { return response.json(); }), fetch("../../component_library_browser/ui/index.html").then(function (response) { return response.text(); })])
    .then(function (result) {
      window.__clbFixture = result[0];
      var parsed = new DOMParser().parseFromString(result[1], "text/html");
      Array.prototype.forEach.call(parsed.body.children, function (node) {
        if (node.tagName !== "SCRIPT") {
          var copy = document.importNode(node, true);
          Array.prototype.forEach.call(copy.querySelectorAll("img[src]"), function (image) {
            image.src = image.getAttribute("src").replace("../icons/", "../../component_library_browser/icons/");
          });
          document.body.appendChild(copy);
        }
      });
      var app = document.createElement("script");
      app.src = "../../component_library_browser/ui/app.js";
      app.onload = function () {
        if (new URLSearchParams(window.location.search).get("verify") === "1") window.setTimeout(runInteractionChecks, 0);
      };
      document.body.appendChild(app);
    })
    .catch(function (error) { document.body.dataset.harnessError = error.message; });
  function runInteractionChecks() {
    var result = document.createElement("output");
    result.id = "harness-result";
    result.style.cssText = "position:fixed;right:12px;bottom:12px;z-index:99;padding:8px;background:#fff;border:1px solid #dfe3e8";
    document.body.appendChild(result);
    try {
      window.ComponentLibrary.setState(window.__clbFixture);
      var search = document.getElementById("search");
      search.value = "Glass door";
      search.dispatchEvent(new Event("input", { bubbles: true }));
      if (document.querySelectorAll(".library-card").length !== 1) throw new Error("search did not filter cards");
      var card = document.querySelector(".library-card");
      card.click();
      if (document.getElementById("details-drawer").hidden) throw new Error("card did not open drawer");
      if (!card.classList.contains("selected")) throw new Error("selected card state is missing");
      var step = document.getElementById("opt-random-step");
      if (step.value !== "90" || !step.disabled) throw new Error("rotation step default/disabled state is wrong");
      document.getElementById("opt-random").click();
      if (step.disabled) throw new Error("rotation step did not enable with random rotation");
      step.value = "361";
      step.dispatchEvent(new Event("change", { bubbles: true }));
      if (step.value !== "360") throw new Error("rotation step did not clamp to 360 degrees");
      if (!callbacks.some(function (entry) { return entry.name === "set_insert_option" && String(entry.payload).indexOf("random_step_degrees") !== -1; })) throw new Error("rotation step callback missing");
      var favorite = document.querySelector(".card-favorite");
      if (!favorite) throw new Error("All scope cards do not expose favorite action");
      favorite.click();
      if (!callbacks.some(function (entry) { return entry.name === "toggle_favorite"; })) throw new Error("card favorite callback missing");
      document.getElementById("drawer-close").click();
      if (document.activeElement !== card) throw new Error("drawer close did not restore card focus");
      var overflow = document.getElementById("library-overflow");
      overflow.click();
      document.querySelector('[data-command="scan_library_folder"]').click();
      if (!callbacks.some(function (entry) { return entry.name === "scan_library_folder"; })) throw new Error("overflow scan callback missing");
      overflow.click();
      document.querySelector('[data-command="export_pack"]').click();
      if (!callbacks.some(function (entry) { return entry.name === "export_pack"; })) throw new Error("overflow export callback missing");
      overflow.click();
      document.querySelector('[data-command="import_pack"]').click();
      if (!callbacks.some(function (entry) { return entry.name === "import_pack"; })) throw new Error("overflow import callback missing");
      document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
      if (!document.getElementById("library-overflow-menu").hidden || document.activeElement !== overflow) throw new Error("Escape did not close overflow menu");
      var arrayState = Object.assign({}, window.__clbFixture, { array_pick_mode: true, array_pick_message: "Выберите источник для массива" });
      window.ComponentLibrary.setState(arrayState);
      if (document.getElementById("array-pick-banner").hidden) throw new Error("array banner is hidden");
      document.querySelector(".library-card").dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
      if (!callbacks.some(function (entry) { return entry.name === "array_pick_from_library"; })) throw new Error("double click did not call array callback");
      window.ComponentLibrary.setState(Object.assign({}, window.__clbFixture, { scope: "in_model", search: "" }));
      var modelCard = document.querySelector(".library-card");
      modelCard.click();
      document.getElementById("primary-insert").click();
      var modelSave = callbacks.find(function (entry) { return entry.name === "modeltab_save_to_library"; });
      if (!modelSave || JSON.parse(modelSave.payload).definition_guid !== "def-001") throw new Error("model save did not send definition_guid JSON payload");
      document.getElementById("drawer-replace").click();
      if (!callbacks.some(function (entry) { return entry.name === "replace_selection_model" && String(entry.payload).indexOf("def-001") !== -1; })) throw new Error("model replace did not use definition_guid callback");
      window.ComponentLibrary.setState(Object.assign({}, window.__clbFixture, { scope: "all", search: "" }));
      var category = document.querySelector(".category-btn");
      window.prompt = function () { return "Architecture renamed"; };
      category.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, clientX: 20, clientY: 20 }));
      document.getElementById("category-rename").click();
      if (!callbacks.some(function (entry) { return entry.name === "category_rename"; })) throw new Error("category rename callback missing");
      result.textContent = "Interaction checks: PASS";
      document.body.dataset.interaction = "pass";
    } catch (error) {
      result.textContent = "Interaction checks: FAIL — " + error.message;
      document.body.dataset.interaction = "fail";
      throw error;
    }
  }
}());
