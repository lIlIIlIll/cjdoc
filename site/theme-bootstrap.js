"use strict";
(() => {
  const themes = ["system", "light", "dark", "paper", "ocean", "forest", "terminal", "violet"];
  let value = "system", query = null;
  try {
    value = localStorage.getItem("cjdoc-theme") || localStorage.getItem("cjdoc-showcase-theme") || "system";
    if (themes.includes(value)) localStorage.setItem("cjdoc-theme", value);
  } catch (_) {}
  try { query = new URLSearchParams(window.location.search).get("theme"); } catch (_) {}
  if (themes.includes(query)) value = query;
  else query = null;
  if (!themes.includes(value)) value = "system";
  const media = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;
  const resolved = () => value === "system"
    ? (media && media.matches ? "dark" : "light") : value;
  document.documentElement.dataset.themeChoice = value;
  document.documentElement.dataset.theme = resolved();
  if (media) {
    const followSystem = () => {
      if (document.documentElement.dataset.themeChoice === "system") {
        document.documentElement.dataset.theme = media.matches ? "dark" : "light";
      }
    };
    if (media.addEventListener) media.addEventListener("change", followSystem);
    else if (media.addListener) media.addListener(followSystem);
  }
  const state = {navigationTheme: query, listening: false};
  const propagate = () => {
    if (!state.navigationTheme || state.listening) return;
    state.listening = true;
    document.addEventListener("click", event => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      const link = event.target && event.target.closest ? event.target.closest("a[href]") : null;
      if (!link) return;
      let target;
      try { target = new URL(link.href, window.location.href); } catch (_) { return; }
      if (target.protocol !== window.location.protocol || target.host !== window.location.host) return;
      target.searchParams.set("theme", state.navigationTheme);
      link.href = target.href;
    }, true);
  };
  propagate();
  globalThis.__CJDOC_THEME__ = {persist(next) {
    let saved = false;
    try { localStorage.setItem("cjdoc-theme", next); saved = true; } catch (_) {}
    if (!saved || state.navigationTheme) {
      try {
        const url = new URL(window.location.href);
        url.searchParams.set("theme", next);
        window.history.replaceState(null, "", url.href);
        state.navigationTheme = next;
        propagate();
      } catch (_) {}
    }
  }};
})();
