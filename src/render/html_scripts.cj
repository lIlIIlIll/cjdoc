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
  const kindFilter = document.querySelector("[data-cjdoc-kind]");
  const packageFilter = document.querySelector("[data-cjdoc-package]");
  const searchStatus = document.querySelector("[data-cjdoc-search-status]");
  let entries = [];
  let visible = [];
  let selected = -1;
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
  const wordParts = (value) => {
    const chars = [...value];
    const words = [];
    let current = "";
    const isWordChar = (char) => /[\\p{L}\\p{N}_]/u.test(char);
    const isUpper = (char) => char !== char.toLocaleLowerCase() && char === char.toLocaleUpperCase();
    const isLower = (char) => char === char.toLocaleLowerCase() && char !== char.toLocaleUpperCase();
    const flush = () => {
      if (!current) return;
      words.push(current.toLocaleLowerCase());
      current = "";
    };
    for (let i = 0; i < chars.length; i += 1) {
      const char = chars[i];
      if (!isWordChar(char)) { flush(); continue; }
      const previous = chars[i - 1];
      const next = chars[i + 1];
      if (current && isUpper(char) && (isLower(previous) ||
          (isUpper(previous) && next && isLower(next)))) flush();
      current += char;
    }
    flush();
    return words;
  };
  const acronym = (value) => wordParts(value).map((word) => Array.from(word)[0]).join("");
  const oneEditApart = (query, candidate) => {
    if (candidate.length > query.length * 2 + 2 || query.length > candidate.length * 2 + 2) return false;
    const queryChars = [...query];
    const candidateChars = [...candidate];
    if (Math.abs(queryChars.length - candidateChars.length) > 1) return false;
    let queryIndex = 0;
    let candidateIndex = 0;
    let edits = 0;
    while (queryIndex < queryChars.length && candidateIndex < candidateChars.length) {
      if (queryChars[queryIndex] === candidateChars[candidateIndex]) {
        queryIndex += 1;
        candidateIndex += 1;
        continue;
      }
      edits += 1;
      if (edits > 1) return false;
      if (queryChars.length === candidateChars.length) {
        queryIndex += 1;
        candidateIndex += 1;
      } else if (queryChars.length > candidateChars.length) {
        queryIndex += 1;
      } else {
        candidateIndex += 1;
      }
    }
    if (queryIndex < queryChars.length || candidateIndex < candidateChars.length) edits += 1;
    return edits === 1;
  };
  const hasOneSpellingError = (entry, query) => {
    const candidates = [entry.name.toLocaleLowerCase(), ...wordParts(entry.name), ...wordParts(entry.qualifiedName)];
    return candidates.some((candidate) => oneEditApart(query, candidate));
  };
  const rank = (entry, parsed) => {
    if (parsed.filters.some((filter) => !fieldValue(entry, filter.field).includes(filter.value))) return -1;
    const terms = parsed.terms.map((term) => term.toLocaleLowerCase()).filter(Boolean);
    const query = terms.join(" ");
    if (!query) return 0;
    const name = entry.name.toLocaleLowerCase();
    const qualified = entry.qualifiedName.toLocaleLowerCase();
    if (name === query) return 0;
    if (qualified === query) return 1;
    if (name.startsWith(query)) return 2;
    if (qualified.startsWith(query)) return 3;
    const haystack = (entry.qualifiedName + " " + entry.kind + " " + entry.packageName + " " + (entry.ownerName || "") + " " + (entry.parameterTypes || []).join(" ") + " " + (entry.returnType || "") + " " + entry.summary).toLocaleLowerCase();
    const words = wordParts(haystack);
    const body = (entry.body || "").toLocaleLowerCase();
    if (terms.every((term) => words.some((word) => word.startsWith(term)))) return 4;
    if (terms.length === 1 && (acronym(entry.name) === query || acronym(entry.qualifiedName) === query)) return 5;
    if (terms.every((term) => haystack.includes(term))) return 6;
    const queryLength = [...query].length;
    if (terms.length === 1 && queryLength >= 4 && queryLength <= 128 && hasOneSpellingError(entry, query)) return 7;
    // Body and contract prose ranks below every name/structured-field match, so a
    // page that merely mentions the word cannot displace an exact symbol result.
    if (body && terms.every((term) => body.includes(term))) return 8;
    return -1;
  };
  const bodySnippet = (text, term) => {
    const at = text.toLocaleLowerCase().indexOf(term);
    if (at < 0) return text.slice(0, 120);
    const from = Math.max(0, at - 12);
    const to = Math.min(text.length, at + term.length + 48);
    return (from > 0 ? "…" : "") + text.slice(from, to) + (to < text.length ? "…" : "");
  };
  const matchedBodySnippet = (entry, parsed) => {
    if (!entry.body) return null;
    const terms = parsed.terms.map((term) => term.toLocaleLowerCase()).filter(Boolean);
    if (!terms.length) return null;
    const body = entry.body.toLocaleLowerCase();
    if (!terms.every((term) => body.includes(term))) return null;
    return bodySnippet(entry.body, terms[0]);
  };
  // The documented block that matched, with the anchor it renders at. Terms are
  // matched against each block's own text, never against the anchor name.
  const matchedSection = (entry, parsed) => {
    if (!Array.isArray(entry.sections) || !entry.sections.length) return null;
    const terms = parsed.terms.map((term) => term.toLocaleLowerCase()).filter(Boolean);
    if (!terms.length) return null;
    for (const section of entry.sections) {
      const text = (section.text || "").toLocaleLowerCase();
      if (terms.every((term) => text.includes(term))) return section;
    }
    return null;
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
    // Read the controls themselves: history restores their values without change events.
    const selectedKind = kindFilter ? kindFilter.value : "";
    const matches = entries.map((entry) => ({entry, rank: rank(entry, parsedQuery)}))
      .filter((item) => item.rank >= 0 && (!selectedKind || item.entry.kind === selectedKind) &&
        (!selectedPackage || item.entry.packageName === selectedPackage))
      .sort((left, right) => left.rank - right.rank ||
        left.entry.qualifiedName.localeCompare(right.entry.qualifiedName) || left.entry.id.localeCompare(right.entry.id));
    visible = matches.slice(0, 20);
    const signatures = globalThis.__CJDOC_SEARCH_SIGNATURES__ || {};
    for (const match of visible) {
      const entry = match.entry;
      const bodyText = matchedBodySnippet(entry, parsedQuery);
      const section = matchedSection(entry, parsedQuery);
      const fieldLabel = match.rank === 8
        ? (isChinese ? "正文" : "Body text") : "";
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
      link.href = root + entry.href + (section ? "#" + section.anchor : "");
      head.className = "search-result-head";
      name.className = "search-result-name";
      name.textContent = entry.name;
      kind.className = "search-kind";
      kind.textContent = entry.kind;
      context.className = "search-context";
      const ownerLabel = entry.ownerName || entry.packageName;
      const moduleLabel = entry.moduleName && entry.moduleName !== entry.packageName
        ? entry.moduleName : "";
      context.textContent = [ownerLabel, moduleLabel].filter(Boolean).join(" · ");
      // Keep exact module identity available for otherwise identical declarations.
      context.title = [entry.qualifiedName, entry.moduleName, entry.moduleId].filter(Boolean).join(" · ");
      head.append(name, kind);
      link.append(head, context);
      const signatureText = signatures[entry.id] || signatures[entry.canonicalId] || "";
      if (signatureText) { signature.className = "search-result-signature"; signature.textContent = signatureText; link.append(signature); }
      if (entry.summary) { summary.className = "search-summary"; summary.textContent = entry.summary; link.append(summary); }
      if (bodyText) {
        const bodyLine = document.createElement("span");
        bodyLine.className = "search-hit-body";
        if (fieldLabel) {
          const field = document.createElement("span");
          field.className = "search-hit-field";
          field.textContent = fieldLabel + " ";
          bodyLine.append(field);
        }
        bodyLine.append(document.createTextNode(bodyText));
        link.append(bodyLine);
      }
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
  entries = index && index.schemaVersion === "cjdoc.search-index/8" && Array.isArray(index.entries)
    ? index.entries : [];
  addOptions(kindFilter, entries.map((entry) => entry.kind));
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
  if (kindFilter) kindFilter.addEventListener("change", render);
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
      if (!themePopover.hidden && !themePopover.contains(event.target) && !themeToggle.contains(event.target)) closeTheme(false);
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && !themePopover.hidden) { event.stopPropagation(); closeTheme(true); }
    }, true);
  }
  const menu = document.querySelector("[data-cjdoc-menu]");
  const sidebar = document.querySelector("#cjdoc-sidebar");
  const siteHeader = document.querySelector(".site-nav");
  const updateHeaderHeight = () => {
    if (!siteHeader) return;
    document.documentElement.style.setProperty("--cjdoc-header-height",
      Math.ceil(siteHeader.getBoundingClientRect().height) + "px");
  };
  updateHeaderHeight();
  if (siteHeader && "ResizeObserver" in window) new ResizeObserver(updateHeaderHeight).observe(siteHeader);
  window.addEventListener("resize", updateHeaderHeight);
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
    // Focus in the same task as the click: the drawer is already displayed and
    // inert on the rest of the document is already applied, so a deferred timer
    // would only add a window where focus sits on a now-inert control.
    if (target) target.focus(); else sidebar.focus();
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
  const contextFilter = document.querySelector("[data-cjdoc-context-filter]");
  const contextEmpty = document.querySelector("[data-cjdoc-context-empty]");
  const filterContext = () => {
    if (!contextFilter) return;
    const query = contextFilter.value.trim().toLocaleLowerCase();
    let visible = 0;
    for (const item of document.querySelectorAll("[data-cjdoc-context-item]")) {
      const matches = !query || (item.textContent || "").toLocaleLowerCase().includes(query);
      item.hidden = !matches;
      if (matches) visible += 1;
    }
    if (contextEmpty) contextEmpty.hidden = !query || visible > 0;
  };
  if (contextFilter) contextFilter.addEventListener("input", filterContext);
  const positionSidebar = () => {
    if (!sidebar) return;
    const context = sidebar.querySelector(".sidebar-context");
    const current = context && [...context.querySelectorAll("a")].find((link) =>
      link.classList.contains("is-current") || (window.location.hash && link.getAttribute("href") === window.location.hash));
    const target = current || context || sidebar.querySelector(".sidebar-package.is-current");
    if (!target) return;
    sidebar.scrollTop = Math.max(0, sidebar.scrollTop + target.getBoundingClientRect().top -
      sidebar.getBoundingClientRect().top - sidebar.clientHeight / 3);
  };
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
  let syncTocVisibility = () => {};
  if (toc && content) {
    const tocList = toc.querySelector("ol");
    const allHeadings = [...content.querySelectorAll("h1, h2, h3, h4, h5, h6")]
      .filter((heading) => !heading.closest(".member-detail"));
    const semanticHeadings = allHeadings.filter((heading) => {
      const role = heading.dataset.cjdocTocRole;
      return role === "api-root" || role === "api" || role === "member" || role === "group";
    });
    const semanticMode = false;
    const headings = allHeadings.filter((heading) => {
      const role = heading.dataset.cjdocTocRole;
      return (role === "api-root" || role === "api" || role === "member" ||
        heading.tagName === "H2" || heading.tagName === "H3") &&
        !heading.classList.contains("signature-heading");
    });
    const usedIds = new Set([...document.querySelectorAll("[id]")].map((node) => node.id));
    const slug = (value, index) => {
      const normalized = value.toLocaleLowerCase().replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "");
      return normalized || "section-" + index;
    };
    const ensureHeadingId = (heading, index) => {
      if (heading.id) return;
      let id = slug(heading.textContent.trim(), index);
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
        if (role === "api-root" || role === "api" || role === "group") {
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
    let updateActiveToc = () => {};
    if (headings.length && "IntersectionObserver" in window) {

      const links = [...tocList.querySelectorAll("a")];
      const byId = new Map(links.map((link) => [link.dataset.tocTarget, link]));
      const setActive = (targetId) => {
        const target = document.getElementById(targetId);
        if (target && target.closest("[hidden]")) return;
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
      updateActiveToc = setActive;
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
    syncTocVisibility = () => {
      const visibleHeadings = headings.filter((heading) => !heading.closest("[hidden]"));
      const visibleIds = new Set(visibleHeadings.map((heading) => heading.id));
      for (const list of [tocList, mobileTocList]) {
        if (!list) continue;
        for (const link of list.querySelectorAll("[data-toc-target]")) {
          link.closest("li").hidden = !visibleIds.has(link.dataset.tocTarget);
        }
      }
      const active = tocList.querySelector(".is-active");
      if (active && !visibleIds.has(active.dataset.tocTarget)) {
        active.classList.remove("is-active");
        if (visibleHeadings.length) updateActiveToc(visibleHeadings[0].id);
      }
      toc.hidden = visibleHeadings.length === 0;
      if (mobileToc) mobileToc.hidden = visibleHeadings.length === 0;
    };
    syncTocVisibility();
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
  for (const button of document.querySelectorAll("[data-cjdoc-copy-link]")) {
    const iconOnly = button.classList.contains("member-action-copy");
    const label = iconOnly ? button.getAttribute("aria-label") : button.textContent;
    const status = iconOnly ? button.parentElement.querySelector("[data-cjdoc-copy-status]") : null;
    button.addEventListener("click", async () => {
      const url = new URL(button.dataset.cjdocCopyLink, window.location.href).href;
      const copied = await copyText(url);
      const message = copied ? (isChinese ? "链接已复制" : "Link copied")
        : (isChinese ? "请选择并复制链接" : "Select and copy the link");
      button.dataset.copyLinkResult = copied ? "copied" : "manual";
      button.dataset.copied = copied ? "true" : "false";
      if (iconOnly) {
        // Preserve the SVG; expose transient feedback through a live region.
        button.setAttribute("aria-label", message);
        button.title = message;
        if (status) status.textContent = message;
      } else {
        button.textContent = message;
      }
      if (!copied) {
        let field = button.parentElement.querySelector("[data-cjdoc-copy-link-fallback]");
        if (!field) {
          field = document.createElement("input");
          field.type = "text";
          field.readOnly = true;
          field.dataset.cjdocCopyLinkFallback = "";
          field.setAttribute("aria-label", isChinese ? "链接地址" : "Link address");
          button.insertAdjacentElement("afterend", field);
        }
        field.value = url;
        field.focus();
        field.select();
      }
      window.setTimeout(() => {
        if (iconOnly) {
          button.setAttribute("aria-label", label);
          button.title = label;
          if (status) status.textContent = "";
        } else {
          button.textContent = label;
        }
        button.dataset.copied = "false";
      }, 1800);
    });
  }
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
  const originFilter = document.querySelector("[data-cjdoc-member-origin]");
  const memberRows = [...document.querySelectorAll("[data-cjdoc-member]")];
  const memberGroups = [...document.querySelectorAll("[data-cjdoc-member-group]")];
  const overloadGroups = [...document.querySelectorAll("[data-cjdoc-overload-group]")];
  const memberStatus = document.querySelector("[data-cjdoc-member-filter-status]");
  const expandMembers = document.querySelector("[data-cjdoc-members-expand]");
  const collapseMembers = document.querySelector("[data-cjdoc-members-collapse]");
  const syncMemberActions = () => {
    const visible = memberRows.filter((member) => !member.hidden);
    if (expandMembers) expandMembers.disabled = !visible.some((member) => !member.open);
    if (collapseMembers) collapseMembers.disabled = !visible.some((member) => member.open);
  };
  let memberTargetNotice = "";
  const applyMemberFilter = () => {
    const query = memberFilter ? memberFilter.value.trim().toLocaleLowerCase() : "";
    const origin = originFilter ? originFilter.value : "";
    let visible = 0;
    for (const row of memberRows) {
      const haystack = (row.dataset.memberName || "") + " " +
        (row.dataset.memberKind || "") + " " + (row.textContent || "");
      const queryMatches = !query || haystack.toLocaleLowerCase().includes(query);
      const originMatches = !origin || row.dataset.memberOrigin === origin;
      const matches = queryMatches && originMatches;
      row.hidden = !matches;
      if (matches) visible += 1;
    }
    // Group boundaries remain in the DOM while filtering, but never leave
    // empty visual cards or claim that all overloads matched the filter.
    for (const group of overloadGroups) {
      const matches = [...group.querySelectorAll(":scope > [data-cjdoc-member]")]
        .filter((member) => !member.hidden).length;
      const total = Number(group.dataset.overloadTotal);
      const label = group.querySelector("[data-cjdoc-overload-count]");
      group.hidden = matches === 0;
      if (label && Number.isFinite(total) && total > 0) {
        label.textContent = matches === total
          ? (isChinese ? total + " 个重载" : total + " overloads")
          : (isChinese ? matches + " / " + total + " 个重载" :
              matches + " of " + total + " overloads");
      }
    }
    for (const group of memberGroups) {
      group.hidden = !group.querySelector("[data-cjdoc-member]:not([hidden])");
    }
    syncTocVisibility();
    syncMemberActions();
    if (memberStatus) {
      const active = Boolean(query || origin || memberTargetNotice);
      if (!active) {
        memberStatus.hidden = true;
      } else {
        const countText = isChinese
          ? "匹配成员：" + visible
          : visible + " matching member" + (visible === 1 ? "" : "s");
        memberStatus.textContent = memberTargetNotice
          ? countText + memberTargetNotice
          : countText;
        memberStatus.hidden = false;
      }
    }
  };
  if (memberFilter) memberFilter.addEventListener("input", () => {
    memberTargetNotice = "";
    applyMemberFilter();
  });
  if (originFilter) originFilter.addEventListener("change", () => {
    memberTargetNotice = "";
    applyMemberFilter();
  });

  const memberStateKey = (() => {
    const project = document.body.dataset.cjdocProject || "";
    const version = document.body.dataset.cjdocDocVersion || "";
    const audience = document.body.dataset.cjdocAudience || "";
    const cfg = document.body.dataset.cjdocCfg || "";
    return "cjdoc-member-state:" + [project, version, audience, cfg, location.pathname].join("|");
  })();
  const navigationEntry = performance.getEntriesByType("navigation")[0];
  const isHistoryNavigation = navigationEntry && navigationEntry.type === "back_forward";
  const saveMemberState = () => {
    try {
      const open = [...document.querySelectorAll("details[data-cjdoc-member][open]")]
        .map((item) => item.id).filter(Boolean);
      sessionStorage.setItem(memberStateKey, JSON.stringify({
        open,
        filter: memberFilter ? memberFilter.value : "",
        origin: originFilter ? originFilter.value : "",
        contextFilter: contextFilter ? contextFilter.value : "",
        sidebarFilter: sidebarFilter ? sidebarFilter.value : "",
        sidebarGroups: savedSidebarState || [...document.querySelectorAll(".sidebar-group")].map((group) => group.open),
        scroll: [window.scrollX, window.scrollY],
        sidebar: sidebar ? sidebar.scrollTop : 0
      }));
    } catch (_) {}
  };
  let savedMemberState = null;
  try {
    const raw = sessionStorage.getItem(memberStateKey);
    if (raw) savedMemberState = JSON.parse(raw);
  } catch (_) {}
  const restoreMemberState = () => {
    if (!savedMemberState || (window.location.hash && !isHistoryNavigation)) return false;
    const state = savedMemberState;
    if (memberFilter && typeof state.filter === "string") memberFilter.value = state.filter;
    if (originFilter && typeof state.origin === "string") originFilter.value = state.origin;
    applyMemberFilter();
    if (Array.isArray(state.open)) {
      for (const item of memberRows) item.open = state.open.includes(item.id);
    }
    syncMemberActions();
    return true;
  };
  const restoreSidebarState = () => {
    if (isHistoryNavigation && savedMemberState) {
      if (contextFilter && typeof savedMemberState.contextFilter === "string") contextFilter.value = savedMemberState.contextFilter;
      if (sidebarFilter && typeof savedMemberState.sidebarFilter === "string") sidebarFilter.value = savedMemberState.sidebarFilter;
      if (Array.isArray(savedMemberState.sidebarGroups)) {
        [...document.querySelectorAll(".sidebar-group")].forEach((group, index) => {
          if (typeof savedMemberState.sidebarGroups[index] === "boolean") group.open = savedMemberState.sidebarGroups[index];
        });
        savedSidebarState = null;
      }
    }
    filterSidebar();
    filterContext();
  };
  for (const member of memberRows) member.addEventListener("toggle", () => {
    syncMemberActions();
    saveMemberState();
  });
  for (const [button, open] of [[expandMembers, true], [collapseMembers, false]]) {
    if (button) button.addEventListener("click", () => {
      for (const member of memberRows) if (!member.hidden) member.open = open;
      syncMemberActions();
      saveMemberState();
    });
  }
  if (memberFilter) memberFilter.addEventListener("input", saveMemberState);
  if (originFilter) originFilter.addEventListener("change", saveMemberState);
  if (contextFilter) contextFilter.addEventListener("input", saveMemberState);
  if (sidebarFilter) sidebarFilter.addEventListener("input", saveMemberState);
  const restoredMembers = restoreMemberState();

  const revealHashTarget = (scroll = false) => {
    if (!window.location.hash || window.location.hash.length <= 1) return;
    let id = window.location.hash.slice(1);
    try { id = decodeURIComponent(id); } catch (_) {}
    const target = document.getElementById(id);
    if (!target) return;
    const member = target.matches("[data-cjdoc-member]")
      ? target : target.closest("[data-cjdoc-member]");
    if (member && member.tagName === "DETAILS") {
      if (member.hidden) {
        if (memberFilter) memberFilter.value = "";
        if (originFilter) originFilter.value = "";
        memberTargetNotice = isChinese
          ? "；已清除筛选以显示链接目标。"
          : ". Filters cleared to reveal the linked member.";
        applyMemberFilter();
      }
      member.hidden = false;
      member.open = true;
      const group = member.closest("[data-cjdoc-member-group]");
      if (group) group.hidden = false;
      syncTocVisibility();
      syncMemberActions();
      if (scroll) requestAnimationFrame(() => member.scrollIntoView({block: "start"}));
    }
    saveMemberState();
  };
  if (!restoredMembers) revealHashTarget(true);
  window.addEventListener("hashchange", () => revealHashTarget(true));
  document.addEventListener("click", (event) => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.target.closest && event.target.closest("a[href]");
    if (!link || !window.location.hash) return;
    let target;
    try { target = new URL(link.href, window.location.href); } catch (_) { return; }
    if (target.href === window.location.href) revealHashTarget(true);
  });
  window.addEventListener("pagehide", saveMemberState);
  restoreSidebarState();
  applyMemberFilter();
  const finishPageLayout = (event) => {
    requestAnimationFrame(() => {
      updateHeaderHeight();
      // Form values may be restored after the deferred script has run.
      filterSidebar();
      filterContext();
      applyMemberFilter();
      if (event && event.persisted) return;
      if (isHistoryNavigation && savedMemberState && sidebar && Number.isFinite(savedMemberState.sidebar) && savedMemberState.sidebar >= 0) {
        sidebar.scrollTop = savedMemberState.sidebar;
      } else positionSidebar();
    });
  };
  finishPageLayout();
  window.addEventListener("pageshow", finishPageLayout);
})();
"""
