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
      document.getElementById("drawer-close").click();
      if (document.activeElement !== card) throw new Error("drawer close did not restore card focus");
      var overflow = document.getElementById("library-overflow");
      overflow.click();
      document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
      if (!document.getElementById("library-overflow-menu").hidden || document.activeElement !== overflow) throw new Error("Escape did not close overflow menu");
      var arrayState = Object.assign({}, window.__clbFixture, { array_pick_mode: true, array_pick_message: "Выберите источник для массива" });
      window.ComponentLibrary.setState(arrayState);
      if (document.getElementById("array-pick-banner").hidden) throw new Error("array banner is hidden");
      document.querySelector(".library-card").dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
      if (!callbacks.some(function (entry) { return entry.name === "array_pick_from_library"; })) throw new Error("double click did not call array callback");
      result.textContent = "Interaction checks: PASS";
      document.body.dataset.interaction = "pass";
    } catch (error) {
      result.textContent = "Interaction checks: FAIL — " + error.message;
      document.body.dataset.interaction = "fail";
      throw error;
    }
  }
}());
