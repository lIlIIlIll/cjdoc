protected package cjdoc.render.browser

protected let HTML_THEME_BOOTSTRAP_SCRIPT = """
(() => {
  document.documentElement.setAttribute("data-cj-js", "");
  const themes = new Set(["system", "light", "dark", "paper", "ocean", "forest", "terminal", "violet"]);
  const fonts = new Set(["serif", "mono-ui"]);
  const sizes = new Set(["s", "l"]);
  const root = document.documentElement;
  const readParam = () => {
    try { return new URLSearchParams(window.location.search).get("theme"); } catch (_) { return null; }
  };
  const readStore = (name) => {
    try { return localStorage.getItem(name); } catch (_) { return null; }
  };
  const readReader = () => {
    try {
      const value = JSON.parse(readStore("cjdoc-reader") || "{}");
      return value && typeof value === "object" && !Array.isArray(value) ? value : {};
    } catch (_) { return {}; }
  };
  const themeName = (value) => themes.has(value) ? value : null;
  // "system" is an explicit choice too: in the URL it overrides a stored theme.
  const queryTheme = themeName(readParam());
  const initialTheme = queryTheme || themeName(readStore("cjdoc-theme")) || "system";
  if (initialTheme === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", initialTheme);
  const reader = readReader();
  if (fonts.has(reader.font)) root.setAttribute("data-cj-font", reader.font);
  if (sizes.has(reader.size)) root.setAttribute("data-cj-size", reader.size);
  if (reader.codeLines === "wrap") root.setAttribute("data-cj-code-lines", "wrap");
  const state = {navigationTheme: queryTheme, linkListenerInstalled: false};
  const installLinkPropagation = () => {
    if (!state.navigationTheme || state.linkListenerInstalled) return;
    state.linkListenerInstalled = true;
    document.addEventListener("click", (event) => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey ||
          event.shiftKey || event.altKey) return;
      const source = event.target;
      const link = source && source.closest ? source.closest("a[href]") : null;
      if (!link) return;
      let target;
      try { target = new URL(link.href, window.location.href); } catch (_) { return; }
      if (target.protocol !== window.location.protocol || target.host !== window.location.host) return;
      target.searchParams.set("theme", state.navigationTheme);
      link.href = target.href;
    }, true);
  };
  installLinkPropagation();
  const updateNavigationUrl = (next) => {
    try {
      const url = new URL(window.location.href);
      url.searchParams.set("theme", next);
      window.history.replaceState(window.history.state, "", url.href);
      state.navigationTheme = next;
      installLinkPropagation();
    } catch (_) { /* history can be unavailable */ }
  };
  globalThis.__CJDOC_THEME__ = {
    persist(next) {
      let saved = false;
      try { localStorage.setItem("cjdoc-theme", next); saved = true; } catch (_) { /* optional */ }
      if (!saved || state.navigationTheme) updateNavigationUrl(next);
    }
  };
})();
"""

// Only projection-owned links are marked. Resolve static links on interaction
// instead of mutating every collapsed member link during page initialization.
internal let HTML_API_LINK_SCRIPT = #"
(() => {
  const sidebar = globalThis.__CJDOC_SIDEBAR_INDEX__;
  const deprecated = sidebar?.version === 3 ? sidebar.deprecated : null;
  globalThis.__CJDOC_DEPRECATION__ = id =>
    deprecated && typeof id === 'string' && id.startsWith('cjdoc:v2:') &&
    Object.hasOwn(deprecated, id) ? deprecated[id] : undefined;
  const web = /^https?:$/.test(location.protocol);
  const route = globalThis.__CJDOC_API_ROUTE__ = web
    ? file => file.replace(/\/index\.html([?#].*)?$/, '/$1') : file => file;
  if (!web) return;
  if (location.pathname.endsWith('/index.html') &&
      document.body.matches('[data-cjdoc-symbol-id],[data-cjdoc-page-id]')) {
    try { history.replaceState(history.state, '', route(location.pathname) + location.search + location.hash); }
    catch (_) {}
  }
  const shorten = event => {
    const link = event.target.closest?.('a[data-cjdoc-api-link]');
    if (link) link.setAttribute('href', route(link.getAttribute('href')));
  };
  for (const event of ['pointerover', 'focusin', 'contextmenu', 'click', 'auxclick'])
    document.addEventListener(event, shorten, true);
})();
"#

private func buildHtmlSearchScript(): String {
    let out = StringBuilder(HTML_SEARCH_KERNEL_PRIMITIVES_SCRIPT.size + HTML_SEARCH_KERNEL_INDEX_SCRIPT.size +
        HTML_SEARCH_KERNEL_MATCHING_SCRIPT.size + HTML_SEARCH_KERNEL_EXECUTION_SCRIPT.size +
        HTML_SEARCH_CONTROLLER_SETUP_SCRIPT.size + HTML_SEARCH_CONTROLLER_RESULTS_SCRIPT.size +
        HTML_SEARCH_CONTROLLER_FIELDS_SCRIPT.size + HTML_SEARCH_CONTROLLER_INTERACTION_SCRIPT.size +
        HTML_READING_OUTLINE_SCRIPT.size +
        HTML_READING_SETTINGS_SCRIPT.size + HTML_READING_COPY_SCRIPT.size + HTML_READING_MEMBERS_SCRIPT.size)
    out.append(HTML_SEARCH_KERNEL_PRIMITIVES_SCRIPT)
    out.append(HTML_SEARCH_KERNEL_INDEX_SCRIPT)
    out.append(HTML_SEARCH_KERNEL_MATCHING_SCRIPT)
    out.append(HTML_SEARCH_KERNEL_EXECUTION_SCRIPT)
    out.append(HTML_SEARCH_CONTROLLER_SETUP_SCRIPT)
    out.append(HTML_SEARCH_CONTROLLER_RESULTS_SCRIPT)
    out.append(HTML_SEARCH_CONTROLLER_FIELDS_SCRIPT)
    out.append(HTML_SEARCH_CONTROLLER_INTERACTION_SCRIPT)
    out.append(HTML_READING_OUTLINE_SCRIPT)
    out.append(HTML_READING_SETTINGS_SCRIPT)
    out.append(HTML_READING_COPY_SCRIPT)
    out.append(HTML_READING_MEMBERS_SCRIPT)
    out.toString()
}

private let HTML_SEARCH_SCRIPT = buildHtmlSearchScript()

// Keep the source indented with one compaction pass for nested bundle lines.
// The canonical asset test excludes literals sensitive to line indentation.
protected let HTML_READER_BUNDLE =
    (HTML_API_LINK_SCRIPT + HTML_SIDEBAR_SCRIPT + HTML_SEARCH_SCRIPT + LANGUAGE_NAVIGATION_SCRIPT)
    .replace("\n    ", "\n")
