package cjdoc.render

internal let HTML_SIDEBAR_SCRIPT = """
(() => {
  const sidebar = document.querySelector("#cjdoc-sidebar");
  const data = globalThis.__CJDOC_SIDEBAR_INDEX__;
  if (!sidebar || !data) return;
  const root = sidebar.dataset.cjdocRootPrefix || "";
  const current = sidebar.dataset.cjdocCurrentSymbol || "";
  const setCurrent = (link, id) => {
    if (id !== current) return;
    link.classList.add("is-current");
    link.setAttribute("aria-current", "page");
  };
  for (const nav of sidebar.querySelectorAll("[data-cjdoc-sidebar-package]")) {
    const ids = data.packages[nav.dataset.cjdocSidebarPackage] || [];
    const selected = ids.indexOf(current);
    const visible = ids.slice(0, selected >= 256 ? 255 : 256);
    if (selected >= 256) visible.push(current);
    const links = document.createDocumentFragment();
    for (const id of visible) {
      const symbol = data.symbols[id];
      const link = document.createElement("a");
      link.className = "sidebar-symbol";
      link.setAttribute("href", root + symbol.path);
      setCurrent(link, id);
      const name = document.createElement("span");
      name.className = "sidebar-symbol-name";
      name.textContent = symbol.label;
      const kind = document.createElement("span");
      kind.className = "sidebar-symbol-kind";
      kind.textContent = symbol.kind;
      link.append(name, kind);
      links.append(link);
    }
    const more = nav.querySelector("[data-cjdoc-sidebar-more]");
    if (more) { more.hidden = ids.length <= 256; links.append(more); }
    nav.replaceChildren(links);
  }
  for (const nav of sidebar.querySelectorAll("[data-cjdoc-context-key]")) {
    const ids = data[nav.dataset.cjdocContextSource][nav.dataset.cjdocContextKey] || [];
    const local = nav.dataset.cjdocContextLocal === "true";
    const links = document.createDocumentFragment();
    for (const id of ids.slice(0, 256)) {
      const symbol = data.symbols[id];
      const link = document.createElement("a");
      link.className = "context-item";
      link.setAttribute("data-cjdoc-context-item", "");
      link.setAttribute("href", local ? "#" + symbol.anchor : root + symbol.path);
      link.setAttribute("title", symbol.signature);
      setCurrent(link, id);
      const name = document.createElement("code");
      name.textContent = symbol.context;
      link.append(name);
      links.append(link);
    }
    nav.replaceChildren(links);
    const section = nav.closest(".sidebar-context");
    const fallback = section.querySelector("[data-cjdoc-context-fallback]");
    const limit = section.querySelector("[data-cjdoc-context-limit]");
    if (fallback) fallback.hidden = true;
    if (limit) limit.hidden = ids.length <= 256;
  }
})();
"""
