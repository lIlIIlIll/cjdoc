package cjdoc.render


internal let HTML_THEME_BOOTSTRAP_SCRIPT = """
(() => {
  const themes = new Set(["system", "light", "dark", "paper", "ocean", "forest", "terminal", "violet"]);
  const isKnownTheme = (value) => themes.has(value);
  const readQueryTheme = () => {
    try {
      const value = new URLSearchParams(window.location.search).get("theme");
      return isKnownTheme(value) ? value : null;
    } catch (_) { return null; }
  };
  const readStoredTheme = () => {
    try { return localStorage.getItem("cjdoc-theme"); } catch (_) { return null; }
  };
  const queryTheme = readQueryTheme();
  const storedTheme = readStoredTheme();
  const initialTheme = queryTheme || (isKnownTheme(storedTheme) ? storedTheme : "system");
  if (initialTheme === "system") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = initialTheme;
  const state = {navigationTheme: queryTheme, linkListenerInstalled: false};
  const installLinkPropagation = () => {
    if (!state.navigationTheme || state.linkListenerInstalled) return;
    state.linkListenerInstalled = true;
    document.addEventListener("click", (event) => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
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
      window.history.replaceState(null, "", url.href);
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

internal let HTML_SEARCH_SCRIPT = """
(() => {
  const input = document.querySelector("[data-cjdoc-search]");
  const results = document.querySelector("[data-cjdoc-results]");
  const isChinese = (document.documentElement.lang || "").toLocaleLowerCase().startsWith("zh");
  const copyLabels = isChinese
    ? {copy: "复制代码", copied: "已复制"}
    : {copy: "Copy code", copied: "Copied"};
  if (input && results) {
  const root = input.dataset.root || "";
  const searchArea = input.closest(".search-area");
  const packageFilter = document.querySelector("[data-cjdoc-package]");
  const categoryTabs = [...document.querySelectorAll("[data-cjdoc-category]")];
  const searchStatus = document.querySelector("[data-cjdoc-search-status]");
  let entries = [];
  let visible = [];
  let selected = -1;
  let activeCategory = "all";
  const categoryFor = (kind) => {
    if (["class", "struct", "interface", "enum", "typeAlias"].includes(kind)) return "classes";
    if (["function", "constructor"].includes(kind)) return "functions";
    return "other";
  };
  const fieldNames = new Set(["name", "owner", "param", "return", "package", "kind"]);
  const parseQuery = (raw) => {
    const filters = [];
    const terms = [];
    const errors = [];
    for (const token of raw.trim().split(/\\s+/).filter(Boolean)) {
      const colon = token.indexOf(":");
      if (colon <= 0) { terms.push(token); continue; }
      const field = token.slice(0, colon).toLocaleLowerCase();
      const value = token.slice(colon + 1).toLocaleLowerCase();
      if (!fieldNames.has(field) || !value) errors.push(token);
      else filters.push({field, value});
    }
    return {filters, terms, errors};
  };
  const fieldValue = (entry, field) => {
    if (field === "param") return (entry.parameterTypes || []).join(" ").toLocaleLowerCase();
    if (field === "return") return [entry.returnType, entry.returnCanonical].filter(Boolean).join(" ").toLocaleLowerCase();
    if (field === "owner") return (entry.ownerName || "").toLocaleLowerCase();
    if (field === "package") return (entry.packageName || "").toLocaleLowerCase();
    return (entry[field] || "").toLocaleLowerCase();
  };
  const rank = (entry, parsed) => {
    if (parsed.filters.some((filter) => !fieldValue(entry, filter.field).includes(filter.value))) return -1;
    const query = parsed.terms.join(" ");
    if (!query) return 0;
    const name = entry.name.toLocaleLowerCase();
    const qualified = entry.qualifiedName.toLocaleLowerCase();
    if (name === query) return 0;
    if (qualified === query) return 1;
    if (name.startsWith(query)) return 2;
    if (qualified.startsWith(query)) return 3;
    const haystack = (entry.qualifiedName + " " + entry.kind + " " + entry.packageName + " " + (entry.ownerName || "") + " " + (entry.parameterTypes || []).join(" ") + " " + (entry.returnType || "") + " " + entry.summary).toLocaleLowerCase();
    return query.split(" ").filter(Boolean).every((token) => haystack.includes(token)) ? 4 : -1;
  };
  const setCategory = (next) => {
    activeCategory = next;
    for (const tab of categoryTabs) {
      const active = tab.dataset.cjdocCategory === next;
      tab.setAttribute("aria-selected", active ? "true" : "false");
      tab.setAttribute("aria-pressed", active ? "true" : "false");
    }
    render();
  };
  const select = (next) => {
    if (!visible.length) return;
    selected = (next + visible.length) % visible.length;
    for (let i = 0; i < results.children.length; i += 1) {
      results.children[i].setAttribute("aria-selected", i === selected ? "true" : "false");
    }
    const active = results.children[selected];
    if (!active) { input.removeAttribute("aria-activedescendant"); return; }
    input.setAttribute("aria-activedescendant", active.id);
    active.scrollIntoView({block: "nearest"});
  };
  const render = () => {
    results.replaceChildren();
    visible = [];
    selected = -1;
    input.removeAttribute("aria-activedescendant");
    if (searchStatus) searchStatus.hidden = true;
    const rawQuery = input.value.trim().toLocaleLowerCase();
    if (!rawQuery) { input.setAttribute("aria-expanded", "false"); return; }
    const parsedQuery = parseQuery(rawQuery);
    if (parsedQuery.errors.length) {
      if (searchStatus) {
        searchStatus.textContent = isChinese ? "筛选语法错误：支持 name:、owner:、param:、return:、package:、kind:" : "Invalid filter; use name:, owner:, param:, return:, package:, or kind:";
        searchStatus.hidden = false;
      }
      input.setAttribute("aria-expanded", "false");
      return;
    }
    const selectedPackage = packageFilter ? packageFilter.value : "";
    const matches = entries.map((entry) => ({entry, rank: rank(entry, parsedQuery)}))
      .filter((item) => item.rank >= 0 && (activeCategory === "all" || categoryFor(item.entry.kind) === activeCategory) &&
        (!selectedPackage || item.entry.packageName === selectedPackage))
      .sort((left, right) => left.rank - right.rank ||
        left.entry.qualifiedName.localeCompare(right.entry.qualifiedName) || left.entry.id.localeCompare(right.entry.id));
    visible = matches.slice(0, 20).map((item) => item.entry);
    const signatures = globalThis.__CJDOC_SEARCH_SIGNATURES__ || {};
    for (const entry of visible) {
      const item = document.createElement("li");
      const link = document.createElement("a");
      const head = document.createElement("span");
      const name = document.createElement("strong");
      const kind = document.createElement("span");
      const context = document.createElement("span");
      const signature = document.createElement("code");
      const summary = document.createElement("span");
      item.id = "cjdoc-search-result-" + results.children.length;
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", "false");
      link.href = root + entry.href;
      head.className = "search-result-head";
      name.className = "search-result-name";
      name.textContent = entry.name;
      kind.className = "search-kind";
      kind.textContent = entry.kind;
      context.className = "search-context";
      const moduleLabel = entry.moduleId
        ? (entry.moduleName ? entry.moduleName + " · " : "") + "module: " + entry.moduleId
        : "";
      context.textContent = [entry.packageName, moduleLabel,
        entry.qualifiedName !== entry.name ? entry.qualifiedName : "",
        entry.ownerName ? "owner: " + entry.ownerName : ""].filter(Boolean).join(" · ");
      head.append(name, kind);
      link.append(head, context);
      const signatureText = signatures[entry.id] || signatures[entry.canonicalId] || "";
      if (signatureText) { signature.className = "search-result-signature"; signature.textContent = signatureText; link.append(signature); }
      if (entry.summary) { summary.className = "search-summary"; summary.textContent = entry.summary; link.append(summary); }
      item.append(link);
      results.append(item);
    }
    if (!visible.length && searchStatus) {
      searchStatus.textContent = isChinese ? "没有匹配的声明" : "No matching declarations";
      searchStatus.hidden = false;
    } else if (matches.length > visible.length && searchStatus) {
      searchStatus.textContent = isChinese
        ? "显示前 " + visible.length + " 项，共 " + matches.length + " 项；请缩小查询范围。"
        : "Showing " + visible.length + " of " + matches.length + " matches; narrow your query for more.";
      searchStatus.hidden = false;
    }
    input.setAttribute("aria-expanded", visible.length ? "true" : "false");
  };

  const addOptions = (selectElement, values) => {
    if (!selectElement) return;
    for (const value of [...new Set(values)].sort((a, b) => a.localeCompare(b))) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value;
      selectElement.append(option);
    }
  };
  const index = globalThis.__CJDOC_SEARCH_INDEX__;
  entries = index && index.schemaVersion === "cjdoc.search-index/6" && Array.isArray(index.entries)
    ? index.entries : [];
  addOptions(packageFilter, entries.map((entry) => entry.packageName));
  const closeSearch = () => {
    visible = [];
    selected = -1;
    results.replaceChildren();
    input.removeAttribute("aria-activedescendant");
    input.setAttribute("aria-expanded", "false");
    if (searchStatus) searchStatus.hidden = true;
  };
  render();
  input.addEventListener("focus", () => { if (input.value.trim()) render(); });
  input.addEventListener("input", render);
  for (const tab of categoryTabs) tab.addEventListener("click", () => setCategory(tab.dataset.cjdocCategory));
  if (packageFilter) packageFilter.addEventListener("change", render);
  input.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") { event.preventDefault(); select(selected + 1); }
    else if (event.key === "ArrowUp") { event.preventDefault(); select(selected < 0 ? visible.length - 1 : selected - 1); }
    else if (event.key === "Enter" && selected >= 0) { const active = results.children[selected]; const link = active && active.querySelector("a"); if (link) { event.preventDefault(); link.click(); } }
    else if (event.key === "Escape") { input.value = ""; render(); input.blur(); }
  });
  document.addEventListener("click", (event) => {
    if (searchArea && !searchArea.contains(event.target) && !event.target.closest(".search-filters") && !event.target.closest("[data-cjdoc-filter-toggle]")) closeSearch();
  });
  document.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLocaleLowerCase() === "k") {
      event.preventDefault();
      if (typeof closeMenu === "function") closeMenu(false);
      input.focus();
      render();
    }
  });
  }
  const filterToggle = document.querySelector("[data-cjdoc-filter-toggle]");
  const filterPanel = document.querySelector("#cjdoc-search-filters");
  const filterArea = filterToggle && filterToggle.closest(".site-search");
  const closeFilters = () => {
    if (!filterToggle || !filterPanel) return;
    filterPanel.classList.remove("is-open");
    filterToggle.setAttribute("aria-expanded", "false");
  };
  if (filterToggle && filterPanel) {
    filterToggle.addEventListener("click", () => {
      const open = !filterPanel.classList.contains("is-open");
      filterPanel.classList.toggle("is-open", open);
      filterToggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
    document.addEventListener("click", (event) => {
      if (filterArea && !filterArea.contains(event.target)) closeFilters();
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape") closeFilters();
    });
  }
  const themeToggle = document.querySelector("[data-cjdoc-theme-toggle]");
  const themePopover = document.querySelector("[data-cjdoc-theme-popover]");
  const themeButtons = [...document.querySelectorAll("[data-cjdoc-theme-value]")];
  const themeValues = new Set(["system", "light", "dark", "paper", "ocean", "forest", "terminal", "violet"]);
  const darkThemes = new Set(["dark", "ocean", "terminal"]);
  const themePersistence = globalThis.__CJDOC_THEME__;
  const isKnownTheme = (value) => themeValues.has(value);
  const readTheme = () => {
    const explicit = document.documentElement.dataset.theme;
    if (isKnownTheme(explicit) && explicit !== "system") return explicit;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  };
  const syncThemeControls = () => {
    const explicit = document.documentElement.dataset.theme;
    const selectedTheme = isKnownTheme(explicit) ? explicit : "system";
    for (const button of themeButtons) {
      const active = button.dataset.cjdocThemeValue === selectedTheme;
      button.setAttribute("aria-pressed", active ? "true" : "false");
    }
    if (themeToggle) themeToggle.dataset.mode = darkThemes.has(readTheme()) ? "dark" : "light";
  };
  const closeTheme = (restoreFocus = false) => {
    if (!themePopover || themePopover.hidden) return;
    themePopover.hidden = true;
    if (themeToggle) {
      themeToggle.setAttribute("aria-expanded", "false");
      if (restoreFocus) themeToggle.focus();
    }
  };
  const setTheme = (next) => {
    if (!isKnownTheme(next)) return;
    if (next === "system") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = next;
    if (themePersistence && typeof themePersistence.persist === "function") themePersistence.persist(next);
    else try { localStorage.setItem("cjdoc-theme", next); } catch (_) { /* optional */ }
    syncThemeControls();
    closeTheme(false);
  };
  if (themeToggle && themePopover) {
    syncThemeControls();
    themeToggle.addEventListener("click", () => {
      const open = themePopover.hidden;
      themePopover.hidden = !open;
      themeToggle.setAttribute("aria-expanded", open ? "true" : "false");
      if (open) { const first = themePopover.querySelector("button"); if (first) first.focus(); }
    });
    for (const button of themeButtons) button.addEventListener("click", () => setTheme(button.dataset.cjdocThemeValue));
    document.addEventListener("click", (event) => {
      if (!themePopover.hidden && !themePopover.contains(event.target) && event.target !== themeToggle) closeTheme(false);
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && !themePopover.hidden) { event.stopPropagation(); closeTheme(true); }
    }, true);
  }
  const menu = document.querySelector("[data-cjdoc-menu]");
  const sidebar = document.querySelector("#cjdoc-sidebar");
  const sidebarClose = document.querySelector("[data-cjdoc-sidebar-close]");
  const menuBackdrop = document.querySelector("[data-cjdoc-menu-backdrop]");
  let opener = null;
  let previousBodyOverflow = "";
  const drawerSurfaces = () => [...document.querySelectorAll(".site-nav, .docs-main, .toc-panel, .site-footer")];
  const setDrawerInert = (value) => {
    for (const surface of drawerSurfaces()) {
      if (value) surface.setAttribute("inert", ""); else surface.removeAttribute("inert");
    }
  };
  const isMobileDrawer = () => window.matchMedia && window.matchMedia("(max-width: 760px)").matches;
  const closeMenu = (restoreFocus = false) => {
    if (!menu || !sidebar) return;
    const wasOpen = menu.getAttribute("aria-expanded") === "true";
    menu.setAttribute("aria-expanded", "false");
    menu.setAttribute("aria-label", isChinese ? "打开导航" : "Open navigation");
    sidebar.classList.remove("is-open");
    sidebar.removeAttribute("role");
    sidebar.removeAttribute("aria-modal");
    document.documentElement.classList.remove("nav-is-open");
    setDrawerInert(false);
    document.body.style.overflow = previousBodyOverflow;
    if (menuBackdrop) menuBackdrop.hidden = true;
    if (restoreFocus && wasOpen && opener && typeof opener.focus === "function") opener.focus();
    opener = null;
  };
  const openMenu = () => {
    if (!menu || !sidebar) return;
    opener = document.activeElement;
    menu.setAttribute("aria-expanded", "true");
    menu.setAttribute("aria-label", isChinese ? "关闭导航" : "Close navigation");
    sidebar.classList.add("is-open");
    sidebar.setAttribute("role", "dialog");
    sidebar.setAttribute("aria-modal", "true");
    document.documentElement.classList.add("nav-is-open");
    setDrawerInert(true);
    previousBodyOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    if (menuBackdrop) menuBackdrop.hidden = false;
    const target = sidebar.querySelector("[data-cjdoc-sidebar-filter], [data-cjdoc-sidebar-close], a, summary");
    if (target) window.setTimeout(() => target.focus(), 0); else window.setTimeout(() => sidebar.focus(), 0);
  };
  if (menu && sidebar) {
    menu.addEventListener("click", () => {
      if (menu.getAttribute("aria-expanded") === "true") closeMenu(true); else openMenu();
    });
    if (sidebarClose) sidebarClose.addEventListener("click", () => closeMenu(true));
    sidebar.addEventListener("click", (event) => { if (event.target.closest("a")) closeMenu(false); });
    if (menuBackdrop) menuBackdrop.addEventListener("click", () => closeMenu(true));
    document.addEventListener("keydown", (event) => {
      if (menu.getAttribute("aria-expanded") !== "true") return;
      if (event.key === "Escape") { closeMenu(true); return; }
      if (event.key !== "Tab") return;
      const focusable = [...sidebar.querySelectorAll("a, button, input, summary, select, [tabindex]")]
        .filter((item) => !item.hidden && !item.disabled && item.tabIndex >= 0 && item.getClientRects().length > 0);
      if (!focusable.length) { event.preventDefault(); sidebar.focus(); return; }
      const first = focusable[0]; const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    });
    window.addEventListener("resize", () => { if (!isMobileDrawer() && menu.getAttribute("aria-expanded") === "true") closeMenu(false); });
  }
  const sidebarFilter = document.querySelector("[data-cjdoc-sidebar-filter]");
  const sidebarNoResults = document.querySelector("[data-cjdoc-sidebar-no-results]");
  let savedSidebarState = null;
  const filterSidebar = () => {
    if (!sidebarFilter) return;
    const query = sidebarFilter.value.trim().toLocaleLowerCase();
    const groups = [...document.querySelectorAll(".sidebar-group")];
    if (query && !savedSidebarState) savedSidebarState = groups.map((group) => group.open);
    let total = 0;
    groups.forEach((group, groupIndex) => {
      let matched = 0;
      for (const item of group.querySelectorAll(".sidebar-package")) {
        const name = item.querySelector("span")?.textContent || "";
        const visible = !query || name.toLocaleLowerCase().includes(query);
        item.hidden = !visible;
        if (visible) matched += 1;
      }
      total += matched;
      group.hidden = matched === 0;
      if (query && matched) group.open = true;
      if (!query && savedSidebarState) group.open = savedSidebarState[groupIndex];
    });
    if (!query) savedSidebarState = null;
    if (sidebarNoResults) sidebarNoResults.hidden = !query || total > 0;
  };
  if (sidebarFilter) sidebarFilter.addEventListener("input", filterSidebar);
  const activePackage = document.querySelector(".sidebar-package.is-current");
  if (activePackage && sidebar) sidebar.scrollTop = Math.max(0, activePackage.offsetTop - sidebar.clientHeight / 3);
  const syncRouteState = () => {
    const overview = document.querySelector(".sidebar-link[href$='index.html']");
    const api = document.querySelector(".sidebar-link[href*='#packages']");
    if (!overview || !api) return;
    const declaredRoute = document.body.dataset.cjdocRoute || "overview";
    const onApi = declaredRoute === "api" || (declaredRoute === "overview" && window.location.hash === "#packages");
    const onOverview = declaredRoute === "overview" && !onApi;
    overview.classList.toggle("is-current", onOverview);
    if (onOverview) overview.setAttribute("aria-current", "page");
    else overview.removeAttribute("aria-current");
    api.classList.toggle("is-current", onApi);
    if (onApi) api.setAttribute("aria-current", "page");
    else api.removeAttribute("aria-current");
  };
  syncRouteState();
  window.addEventListener("hashchange", syncRouteState);
  window.addEventListener("popstate", syncRouteState);
  const toc = document.querySelector("[data-cjdoc-toc]");
  const content = document.querySelector("[data-cjdoc-content]");
  if (toc && content) {
    const tocList = toc.querySelector("ol");
    const allHeadings = [...content.querySelectorAll("h1, h2, h3, h4")]
      .filter((heading) => !heading.closest(".member-detail"));
    const semanticHeadings = allHeadings.filter((heading) => {
      const role = heading.dataset.cjdocTocRole;
      return role === "api-root" || role === "api" || role === "member";
    });
    const semanticMode = false;
    const headings = allHeadings.filter((heading) => {
      const role = heading.dataset.cjdocTocRole;
      return (role === "api-root" || role === "api" || role === "member" ||
        heading.tagName === "H2" || heading.tagName === "H3") &&
        !heading.classList.contains("signature-heading");
    });
    const usedIds = new Set();
    const slug = (value, index) => {
      const normalized = value.toLocaleLowerCase().replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "");
      return normalized || "section-" + index;
    };
    const ensureHeadingId = (heading, index) => {
      let id = heading.id || slug(heading.textContent.trim(), index);
      const base = id;
      let suffix = 2;
      while (usedIds.has(id)) { id = base + "-" + suffix; suffix += 1; }
      heading.id = id;
      usedIds.add(id);
    };
    const headingLabel = (heading) => {
      const explicit = heading.dataset.cjdocTocLabel;
      return (explicit || heading.textContent).trim().replace(/\\s+/g, " ");
    };
    const createLink = (heading, className) => {
      const link = document.createElement("a");
      const sourceLink = heading.querySelector("a[href]");
      const target = sourceLink ? sourceLink.getAttribute("href") : null;
      link.className = "toc-link " + className;
      link.setAttribute("href", target || "#" + heading.id);
      link.dataset.tocTarget = heading.id;
      link.textContent = headingLabel(heading);
      return link;
    };
    const appendFlatItem = (heading, index) => {
      const item = document.createElement("li");
      item.dataset.depth = heading.tagName === "H3" ? "3" : "2";
      item.append(createLink(heading, "toc-flat-link"));
      tocList.append(item);
    };
    const isChinese = (document.documentElement.lang || "").toLocaleLowerCase().startsWith("zh");
    const createToggle = (labelText, children, initiallyExpanded) => {
      const button = document.createElement("button");
      const icon = document.createElement("span");
      const setExpanded = (expanded) => {
        button.setAttribute("aria-expanded", expanded ? "true" : "false");
        button.setAttribute("aria-label", (expanded
          ? (isChinese ? "收起 " : "Collapse ") : (isChinese ? "展开 " : "Expand ")) + labelText);
        icon.textContent = expanded ? "▾" : "▸";
        children.hidden = !expanded;
      };
      button.type = "button";
      button.className = "toc-toggle";
      button.setAttribute("aria-controls", children.id);
      icon.className = "toc-toggle-icon";
      icon.setAttribute("aria-hidden", "true");
      button.append(icon);
      button.addEventListener("click", () => {
        setExpanded(button.getAttribute("aria-expanded") !== "true");
      });
      setExpanded(initiallyExpanded);
      return {button, setExpanded};
    };
    const parentByLink = new Map();
    const apiNodes = [];
    const createApiNode = (heading, index) => {
      const item = document.createElement("li");
      const row = document.createElement("div");
      const link = createLink(heading, "toc-api-link");
      item.className = "toc-api-item";
      row.className = "toc-api-row";
      row.append(link);
      item.append(row);
      const node = {heading, item, row, link, children: null, setExpanded: null, index};
      apiNodes.push(node);
      return node;
    };
    const appendMember = (parent, heading) => {
      if (!parent.children) {
        const children = document.createElement("ol");
        children.className = "toc-children";
        children.id = "toc-children-" + parent.index;
        const toggle = createToggle(headingLabel(parent.heading), children,
          parent.heading.dataset.cjdocTocRole === "api-root");
        parent.children = children;
        parent.setExpanded = toggle.setExpanded;
        parent.row.insertBefore(toggle.button, parent.row.firstChild);
        parent.item.append(children);
      }
      const item = document.createElement("li");
      const link = createLink(heading, "toc-member-link");
      item.className = "toc-member-item";
      item.append(link);
      parent.children.append(item);
      parentByLink.set(link, parent);
    };
    for (let index = 0; index < headings.length; index += 1) {
      ensureHeadingId(headings[index], index);
    }
    tocList.replaceChildren();
    if (semanticMode) {
      let currentApi = null;
      for (const heading of headings) {
        const role = heading.dataset.cjdocTocRole;
        if (role === "api-root" || role === "api") {
          currentApi = createApiNode(heading, apiNodes.length);
          tocList.append(currentApi.item);
        } else if (role === "member" && currentApi) {
          appendMember(currentApi, heading);
        }
      }
    } else {
      for (let index = 0; index < headings.length; index += 1) {
        appendFlatItem(headings[index], index);
      }
    }
    toc.hidden = headings.length === 0;
    const mobileToc = document.querySelector("[data-cjdoc-mobile-toc]");
    const mobileTocList = mobileToc && mobileToc.querySelector("ol");
    if (mobileToc && mobileTocList) {
      mobileTocList.replaceChildren();
      for (const heading of headings) {
        const item = document.createElement("li");
        item.append(createLink(heading, "toc-mobile-link"));
        mobileTocList.append(item);
      }
      mobileToc.hidden = headings.length === 0;
    }
    if (headings.length && "IntersectionObserver" in window) {

      const links = [...tocList.querySelectorAll("a")];
      const byId = new Map(links.map((link) => [link.dataset.tocTarget, link]));
      const setActive = (targetId) => {
        for (const link of links) {
          link.classList.remove("is-active", "is-parent-active");
        }
        const active = byId.get(targetId);
        if (!active) return;
        active.classList.add("is-active");
        const parent = parentByLink.get(active);
        if (parent) {
          parent.link.classList.add("is-parent-active");
          parent.setExpanded(true);
        }
      };
      for (const link of links) {
        link.addEventListener("click", () => {
          const parent = parentByLink.get(link);
          if (parent) parent.setExpanded(true);
          setActive(link.dataset.tocTarget);
        });
      }
      const observer = new IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          setActive(entry.target.id);
        }
      }, {rootMargin: "-18% 0px -68% 0px", threshold: 0});
      for (const heading of headings) observer.observe(heading);
      setActive(headings[0].id);
    } else if (headings.length) {
      const firstLink = tocList.querySelector("a");
      if (firstLink) firstLink.classList.add("is-active");
    }
  }
  const copyText = async (value) => {
    if (navigator.clipboard && window.isSecureContext) {
      try { await navigator.clipboard.writeText(value); return true; } catch (_) { /* fallback */ }
    }
    const previousFocus = document.activeElement;
    const area = document.createElement("textarea");
    area.value = value; area.setAttribute("readonly", "");
    area.style.position = "fixed"; area.style.opacity = "0";
    document.body.append(area); area.select();
    let copied = false;
    try { copied = document.execCommand("copy"); } catch (_) { copied = false; }
    area.remove();
    if (previousFocus && typeof previousFocus.focus === "function") previousFocus.focus();
    return copied;
  };
  for (const code of document.querySelectorAll("pre > code")) {
    const pre = code.parentElement;
    if (pre.querySelector("[data-cjdoc-copy]")) continue;
    const button = document.createElement("button");
    button.type = "button"; button.className = "code-copy";
    button.setAttribute("aria-label", copyLabels.copy);
    button.title = copyLabels.copy;
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    const front = document.createElementNS(svg.namespaceURI, "rect");
    const back = document.createElementNS(svg.namespaceURI, "path");
    for (const [key, value] of Object.entries({width: "16", height: "16", viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": "1.8", "aria-hidden": "true"})) svg.setAttribute(key, value);
    for (const [key, value] of Object.entries({x: "8", y: "8", width: "11", height: "11", rx: "2"})) front.setAttribute(key, value);
    back.setAttribute("d", "M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2");
    svg.append(front, back); button.append(svg); pre.append(button);
    button.addEventListener("click", async () => {
      const copied = await copyText(code.textContent || "");
      button.dataset.copied = copied ? "true" : "false";
      button.setAttribute("aria-label", copied ? copyLabels.copied : copyLabels.copy);
      button.title = copied ? copyLabels.copied : copyLabels.copy;
      if (copied) window.setTimeout(() => {
        button.dataset.copied = "false";
        button.setAttribute("aria-label", copyLabels.copy);
        button.title = copyLabels.copy;
      }, 1400);
    });
  }
  const memberFilter = document.querySelector("[data-cjdoc-member-filter]");
  if (memberFilter) {
    const memberRows = [...document.querySelectorAll("[data-cjdoc-member]")];
    const memberGroups = [...document.querySelectorAll("[data-cjdoc-member-group]")];
    const memberStatus = document.querySelector("[data-cjdoc-member-filter-status]");
    const applyMemberFilter = () => {
      const query = memberFilter.value.trim().toLocaleLowerCase();
      let visible = 0;
      for (const row of memberRows) {
        const haystack = (row.dataset.memberName || "") + " " + (row.dataset.memberKind || "") + " " + (row.textContent || "");
        const matches = !query || haystack.toLocaleLowerCase().includes(query);
        row.hidden = !matches;
        if (matches) visible += 1;
      }
      for (const group of memberGroups) {
        group.hidden = query && !group.querySelector("[data-cjdoc-member]:not([hidden])");
      }
      if (memberStatus) memberStatus.hidden = !query || visible !== 0;
    };
    memberFilter.addEventListener("input", applyMemberFilter);
  }
  const revealHashTarget = () => {
    if (!window.location.hash || window.location.hash.length <= 1) return;
    let id = window.location.hash.slice(1);
    try { id = decodeURIComponent(id); } catch (_) {}
    const target = document.getElementById(id);
    if (!target) return;
    const member = target.matches("[data-cjdoc-member]") ? target : target.closest("[data-cjdoc-member]");
    if (member && member.tagName === "DETAILS") {
      member.hidden = false;
      member.open = true;
      const group = member.closest("[data-cjdoc-member-group]");
      if (group) group.hidden = false;
      if (memberFilter && memberFilter.value) {
        memberFilter.value = "";
        memberFilter.dispatchEvent(new Event("input", {bubbles: true}));
      }
    }
  };
  revealHashTarget();
  window.addEventListener("hashchange", revealHashTarget);
})();
"""
