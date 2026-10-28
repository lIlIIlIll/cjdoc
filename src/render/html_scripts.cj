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
  const kindLabels = {function: "函数", constructor: "构造器", property: "属性", variable: "变量",
    class: "类", struct: "结构体", interface: "接口", enum: "枚举", enumCase: "枚举项",
    extend: "扩展", typeAlias: "类型别名", concept: "指南", macro: "宏"};
  const kindLabel = value => isChinese ? (kindLabels[value] || value) : value;
  const copyLabels = isChinese
    ? {copy: "复制代码", copied: "已复制"}
    : {copy: "Copy code", copied: "Copied"};
  if (input && results) {
  const root = input.dataset.root || "";
  const searchArea = input.closest(".search-area");
  const mobileSearchTrigger = document.querySelector("[data-cjdoc-search-trigger]");
  const closeMobileSearch = (restoreFocus = false) => {
    if (!mobileSearchTrigger) return;
    document.documentElement.classList.remove("mobile-search-is-open");
    mobileSearchTrigger.setAttribute("aria-expanded", "false");
    mobileSearchTrigger.setAttribute("aria-label", isChinese ? "打开搜索" : "Open search");
    if (restoreFocus) mobileSearchTrigger.focus();
  };
  const openMobileSearch = () => {
    if (!mobileSearchTrigger) return;
    document.documentElement.classList.add("mobile-search-is-open");
    mobileSearchTrigger.setAttribute("aria-expanded", "true");
    mobileSearchTrigger.setAttribute("aria-label", isChinese ? "关闭搜索" : "Close search");
    input.focus();
  };
  if (mobileSearchTrigger) {
    mobileSearchTrigger.addEventListener("click", () => {
      if (mobileSearchTrigger.getAttribute("aria-expanded") === "true") {
        closeMobileSearch(true);
      } else { openMobileSearch(); }
    });
    input.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && mobileSearchTrigger.getAttribute("aria-expanded") === "true") {
        closeMobileSearch(true);
      }
    });
  }
  const kindFilter = document.querySelector("[data-cjdoc-kind]");
  const packageFilter = document.querySelector("[data-cjdoc-package]");
  const searchStatus = document.querySelector("[data-cjdoc-search-status]");
  const searchPopover = document.querySelector("[data-cjdoc-search-popover]");
  const searchPages = document.querySelector("[data-cjdoc-search-pages]");
  const previousPage = document.querySelector("[data-cjdoc-search-previous]");
  const nextPage = document.querySelector("[data-cjdoc-search-next]");
  const pageSize = 20;
  let matches = [];
  let currentPage = 0;
  let currentQuery = null;
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
  // Cache only immutable entry facts, bounded by this page's native index.
  // Distinct queries still run the same ranking and stable tie-breaks.
  const entryTextCache = new WeakMap();
  const entryText = (entry) => {
    let text = entryTextCache.get(entry);
    if (!text) {
      const haystack = (entry.qualifiedName + " " + entry.kind + " " + entry.packageName + " " + (entry.ownerName || "") + " " + (entry.parameterTypes || []).join(" ") + " " + (entry.returnType || "") + " " + entry.summary).toLocaleLowerCase();
      text = {haystack, words: wordParts(haystack)};
      entryTextCache.set(entry, text);
    }
    return text;
  };
  const wordInitials = (words) => words.map((word) => Array.from(word)[0]).join("");
  const entrySpelling = (entry, text) => {
    if (!text.spelling) {
      const nameWords = wordParts(entry.name);
      const qualifiedWords = wordParts(entry.qualifiedName);
      text.spelling = {
        nameAcronym: wordInitials(nameWords),
        qualifiedAcronym: wordInitials(qualifiedWords),
        candidates: [entry.name.toLocaleLowerCase(), ...nameWords, ...qualifiedWords]
      };
    }
    return text.spelling;
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
    const text = entryText(entry);
    const haystack = text.haystack;
    const words = text.words;
    const body = (entry.body || "").toLocaleLowerCase();
    if (terms.every((term) => words.some((word) => word.startsWith(term)))) return 4;
    const spelling = terms.length === 1 ? entrySpelling(entry, text) : null;
    if (spelling && (spelling.nameAcronym === query || spelling.qualifiedAcronym === query)) return 5;
    if (terms.every((term) => haystack.includes(term))) return 6;
    const queryLength = [...query].length;
    if (spelling && queryLength >= 4 && queryLength <= 128 &&
        spelling.candidates.some((candidate) => oneEditApart(query, candidate))) return 7;
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
  const renderPage = (parsedQuery) => {
    results.replaceChildren();
    selected = -1;
    input.removeAttribute("aria-activedescendant");
    const start = currentPage * pageSize;
    visible = matches.slice(start, start + pageSize);
    const signatures = globalThis.__CJDOC_SEARCH_SIGNATURES__ || {};
    for (const match of visible) {
      const entry = match.entry;
      const bodyText = matchedBodySnippet(entry, parsedQuery);
      // A section fragment is only correct for a body-text hit (rank 8). A
      // name or structured-field match belongs at the member top, even when the
      // same query word also appears in a documented block.
      const section = match.rank === 8 ? matchedSection(entry, parsedQuery) : null;
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
      kind.textContent = kindLabel(entry.kind);
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
    if (searchStatus) {
      searchStatus.textContent = !visible.length
        ? (isChinese ? "此索引中没有匹配项。" : "No matches in this index.")
        : (isChinese ? "显示 " : "Showing ") + (start + 1) + "–" + (start + visible.length) +
          (isChinese ? " 项，共 " : " of ") + matches.length + (isChinese ? " 项。" : " matches.");
      searchStatus.hidden = false;
    }
    if (searchPages) searchPages.hidden = matches.length <= pageSize;
    if (previousPage) previousPage.disabled = currentPage === 0;
    if (nextPage) nextPage.disabled = start + pageSize >= matches.length;
    if (searchPopover) searchPopover.hidden = false;
    input.setAttribute("aria-expanded", visible.length ? "true" : "false");
  };
  const render = () => {
    closeSearch();
    matches = [];
    currentPage = 0;
    const rawQuery = input.value.trim().toLocaleLowerCase();
    if (!rawQuery) return;
    const parsedQuery = parseQuery(rawQuery);
    if (parsedQuery.errors.length) {
      if (searchStatus) {
        searchStatus.textContent = isChinese ? "筛选语法错误：支持 name:、owner:、param:、return:、package:、kind:" : "Invalid filter; use name:, owner:, param:, return:, package:, or kind:";
        searchStatus.hidden = false;
      }
      if (searchPopover) searchPopover.hidden = false;
      return;
    }
    // Read restored controls on every new query; page changes reuse its stable ranking.
    const selectedPackage = packageFilter ? packageFilter.value : "";
    const selectedKind = kindFilter ? kindFilter.value : "";
    matches = entries.map((entry) => ({entry, rank: rank(entry, parsedQuery)}))
      .filter((item) => item.rank >= 0 && (!selectedKind || item.entry.kind === selectedKind) &&
        (!selectedPackage || item.entry.packageName === selectedPackage))
      .sort((left, right) => left.rank - right.rank ||
        left.entry.qualifiedName.localeCompare(right.entry.qualifiedName) || left.entry.id.localeCompare(right.entry.id));
    currentQuery = parsedQuery;
    renderPage(parsedQuery);
  };
  const changePage = (offset) => {
    const page = currentPage + offset;
    if (!currentQuery || page < 0 || page * pageSize >= matches.length) return;
    currentPage = page;
    renderPage(currentQuery);
    // Keep keyboard users on the new results, not a now-disabled final-page button.
    const first = results.querySelector("a");
    if (first) first.focus();
    results.scrollTop = 0;
  };
  if (previousPage) previousPage.addEventListener("click", () => changePage(-1));
  if (nextPage) nextPage.addEventListener("click", () => changePage(1));

  const addOptions = (selectElement, values, display = value => value) => {
    if (!selectElement) return;
    // Conceptual search entries have no package name. Do not append an empty
    // <option> after the localized "All packages" placeholder: selecting it
    // makes the filter appear blank while its value still means "all".
    const choices = values.filter(value => typeof value === "string" && value.trim() !== "");
    for (const value of [...new Set(choices)].sort((a, b) => a.localeCompare(b))) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = display(value);
      selectElement.append(option);
    }
  };
  const index = globalThis.__CJDOC_SEARCH_INDEX__;
  entries = index && index.schemaVersion === "cjdoc.search-index/9" && Array.isArray(index.entries)
    ? index.entries : [];
  addOptions(kindFilter, entries.map((entry) => entry.kind), kindLabel);
  addOptions(packageFilter, entries.map((entry) => entry.packageName));
  const closeSearch = () => {
    visible = [];
    selected = -1;
    results.replaceChildren();
    input.removeAttribute("aria-activedescendant");
    input.setAttribute("aria-expanded", "false");
    if (searchStatus) searchStatus.hidden = true;
    if (searchPages) searchPages.hidden = true;
    if (searchPopover) searchPopover.hidden = true;
  };
  render();
  // While an input method editor composes (for example Chinese pinyin), the
  // intermediate text must not drive the result list, and Enter must commit the
  // composition rather than open a result.
  let composing = false;
  const isComposing = (event) => composing || (event && event.isComposing === true);
  input.addEventListener("compositionstart", () => { composing = true; });
  input.addEventListener("compositionend", () => { composing = false; render(); });
  const showSearch = () => {
    if (!input.value.trim() || (searchPopover && !searchPopover.hidden)) return;
    if (currentQuery && matches.length) renderPage(currentQuery);
    else render();
  };
  input.addEventListener("focus", showSearch);
  input.addEventListener("input", (event) => { if (isComposing(event)) return; render(); });
  if (kindFilter) kindFilter.addEventListener("change", render);
  if (packageFilter) packageFilter.addEventListener("change", render);
  (searchArea || input).addEventListener("keydown", (event) => {
    // Escape stays usable mid-composition; navigation and activation do not.
    if (event.key === "Escape") {
      input.value = "";
      render();
      if (event.target === input) input.blur();
      else input.focus();
      return;
    }
    if (isComposing(event)) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const focused = event.target.closest('[role="option"]');
      const position = focused ? Array.prototype.indexOf.call(results.children, focused) : -1;
      const active = position >= 0 ? position : selected;
      select(event.key === "ArrowDown" ? active + 1 : active < 0 ? visible.length - 1 : active - 1);
      if (event.target !== input && selected >= 0) results.children[selected].querySelector("a").focus();
    } else if (event.key === "Enter" && event.target === input && selected >= 0) {
      const active = results.children[selected];
      const link = active && active.querySelector("a");
      if (link) { event.preventDefault(); link.click(); }
    }
  });
  document.addEventListener("click", (event) => {
    if (searchArea && !searchArea.contains(event.target) && !event.target.closest(".search-filters") && !event.target.closest("[data-cjdoc-filter-toggle]")) closeSearch();
  });
  document.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLocaleLowerCase() === "k") {
      event.preventDefault();
      closeTheme(false);
      if (typeof closeMenu === "function") closeMenu(false);
      openMobileSearch();
      input.focus();
      showSearch();
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
    const filterControls = [...filterPanel.querySelectorAll("select")];
    const syncFilterLabel = () => {
      const count = filterControls.filter(control => control.value).length;
      filterToggle.textContent = (isChinese ? "检索筛选" : "Search filters") + (count ? " (" + count + ")" : "");
    };
    for (const control of filterControls) {
      if (control) control.addEventListener("change", syncFilterLabel);
    }
    syncFilterLabel();
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
  const themeBackdrop = document.querySelector("[data-cjdoc-theme-backdrop]");
  const themeClose = document.querySelector("[data-cjdoc-theme-close]");
  const themeLabel = document.querySelector("[data-cjdoc-theme-label]");
  const themeButtons = [...document.querySelectorAll("[data-cjdoc-theme-value]")];
  const themeValues = new Set(["system", "light", "dark", "paper", "ocean", "forest", "terminal", "violet"]);
  const themePersistence = globalThis.__CJDOC_THEME__;
  const isKnownTheme = (value) => themeValues.has(value);
  const selectedTheme = () => {
    const explicit = document.documentElement.dataset.theme;
    return isKnownTheme(explicit) ? explicit : "system";
  };
  const syncThemeControls = () => {
    const selected = selectedTheme();
    for (const button of themeButtons) {
      button.setAttribute("aria-pressed", button.dataset.cjdocThemeValue === selected ? "true" : "false");
    }
    if (themeLabel) {
      const active = themeButtons.find((button) => button.dataset.cjdocThemeValue === selected);
      if (active) {
        themeLabel.textContent = (isChinese ? "主题：" : "Theme: ") + active.textContent.trim();
        if (themeToggle) themeToggle.setAttribute("aria-label",
          (isChinese ? "选择主题：" : "Select theme: ") + active.textContent.trim());
      }
    }
  };
  const isMobileTheme = () => Boolean(window.matchMedia &&
    window.matchMedia("(max-width: 760px)").matches);
  let themeModalActive = false;
  let themeInertNodes = [];
  const setThemeModal = (active) => {
    if (!themePopover || themeModalActive === active) return;
    themeModalActive = active;
    if (active) {
      themePopover.setAttribute("role", "dialog");
      themePopover.setAttribute("aria-modal", "true");
      const isolate = (node) => {
        if (node === themePopover || node === themeBackdrop) return;
        if (node.contains(themePopover) ||
          (themeBackdrop && node.contains(themeBackdrop))) {
          for (const child of node.children) isolate(child);
        } else {
          themeInertNodes.push([node, node.inert]);
          node.inert = true;
        }
      };
      if (document.body) for (const child of document.body.children) isolate(child);
    } else {
      for (const [node, previous] of themeInertNodes) node.inert = previous;
      themeInertNodes = [];
      themePopover.setAttribute("role", "group");
      themePopover.removeAttribute("aria-modal");
    }
  };
  const trapThemeFocus = (event) => {
    if (!themeModalActive || themePopover.hidden || event.key !== "Tab") return;
    const items = [...themePopover.querySelectorAll("button:not([disabled]), a[href], [tabindex]")]
      .filter((node) => !node.hidden && node.tabIndex >= 0 && node.getClientRects().length > 0);
    const first = items[0], last = items[items.length - 1];
    if (!first) { event.preventDefault(); themePopover.focus(); return; }
    if (event.shiftKey && (document.activeElement === first ||
      !themePopover.contains(document.activeElement))) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && (document.activeElement === last ||
      !themePopover.contains(document.activeElement))) {
      event.preventDefault();
      first.focus();
    }
  };
  const closeTheme = (restoreFocus = false) => {
    if (!themePopover || themePopover.hidden) return;
    themePopover.hidden = true;
    if (themeBackdrop) themeBackdrop.hidden = true;
    setThemeModal(false);
    document.documentElement.classList.remove("theme-is-open");
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
    closeTheme(true);
  };
  if (themeToggle && themePopover) {
    syncThemeControls();
    themeToggle.addEventListener("click", () => {
      const open = themePopover.hidden;
      themePopover.hidden = !open;
      if (themeBackdrop) themeBackdrop.hidden = !open;
      document.documentElement.classList.toggle("theme-is-open", open);
      setThemeModal(open && isMobileTheme());
      themeToggle.setAttribute("aria-expanded", open ? "true" : "false");
      if (open) {
        const active = themePopover.querySelector('[aria-pressed="true"]');
        if (active) active.focus();
      }
    });
    for (const button of themeButtons) button.addEventListener("click", () => setTheme(button.dataset.cjdocThemeValue));
    if (themeBackdrop) themeBackdrop.addEventListener("click", () => closeTheme(true));
    if (themeClose) themeClose.addEventListener("click", () => closeTheme(true));
    document.addEventListener("click", (event) => {
      if (!themePopover.hidden && !themePopover.contains(event.target) && !themeToggle.contains(event.target)) closeTheme(false);
    });
    document.addEventListener("keydown", (event) => {
      trapThemeFocus(event);
      if (event.key === "Escape" && !themePopover.hidden) { event.stopPropagation(); closeTheme(true); }
    }, true);
    window.addEventListener("resize", () => {
      if (!themePopover.hidden) setThemeModal(isMobileTheme());
    });
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
        // Hide the entire package node, including its nested symbol list.
        const entry = item.closest(".sidebar-package-entry");
        if (entry) entry.hidden = !visible;
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
    const selectedSymbol = sidebar.querySelector(".sidebar-symbol.is-current");
    const target = current || selectedSymbol || context || sidebar.querySelector(".sidebar-package.is-current");
    if (!target) return;
    sidebar.scrollTop = Math.max(0, sidebar.scrollTop + target.getBoundingClientRect().top -
      sidebar.getBoundingClientRect().top - sidebar.clientHeight / 3);
  };
  const syncRouteState = () => {
    const overview = document.querySelector(".sidebar-link[href$='index.html']");
    const quickStart = document.querySelector(".sidebar-link[href*='#quick-start-title']");
    const api = document.querySelector(".sidebar-link[href*='#packages']");
    if (!overview || !api) return;
    const declaredRoute = document.body.dataset.cjdocRoute || "overview";
    const onApi = declaredRoute === "api" ||
      (declaredRoute === "overview" && window.location.hash === "#packages");
    const onQuickStart = declaredRoute === "overview" &&
      window.location.hash === "#quick-start-title";
    const onOverview = declaredRoute === "overview" && !onApi && !onQuickStart;
    for (const [link, active] of [[overview, onOverview], [quickStart, onQuickStart], [api, onApi]]) {
      if (!link) continue;
      link.classList.toggle("is-current", active);
      if (active) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    }
  };
  syncRouteState();
  window.addEventListener("hashchange", syncRouteState);
  window.addEventListener("popstate", syncRouteState);
  const toc = document.querySelector("[data-cjdoc-toc]");
  const content = document.querySelector("[data-cjdoc-content]");
  let syncTocVisibility = () => {};
  if (toc && content) {
    const tocList = toc.querySelector("ol");
    const allHeadings = [...content.querySelectorAll("h1, h2, h3, h4, h5, h6, [data-cjdoc-toc-role='member']")]
      .filter((heading) => !heading.closest(".member-detail") ||
        heading.dataset.cjdocTocRole === "member");
    const semanticHeadings = allHeadings.filter((heading) => {
      const role = heading.dataset.cjdocTocRole;
      return role === "api-root" || role === "api" || role === "member" || role === "group";
    });
    const semanticMode = false;
    const headings = allHeadings.filter((heading) => {
      if (heading.closest(".home-api-index")) return false;
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
    const tocTargetId = (heading) => {
      if (heading.dataset.cjdocTocRole === "member") {
        const member = heading.closest(".member-detail");
        if (member && member.id) return member.id;
      }
      return heading.id;
    };
    const createLink = (heading, className) => {
      const link = document.createElement("a");
      const sourceLink = heading.querySelector("a[href]");
      const target = heading.dataset.cjdocTocRole === "member"
        ? null : (sourceLink ? sourceLink.getAttribute("href") : null);
      link.className = "toc-link " + className;
      const targetId = tocTargetId(heading);
      link.setAttribute("href", target || "#" + targetId);
      link.dataset.tocTarget = targetId;
      link.textContent = headingLabel(heading);
      return link;
    };
    const appendFlatItem = (heading, index) => {
      const item = document.createElement("li");
      item.dataset.depth = heading.tagName === "H3" || heading.dataset.cjdocTocRole === "member" ? "3" : "2";
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
          setActive(tocTargetId(entry.target));
        }
      }, {rootMargin: "-18% 0px -68% 0px", threshold: 0});
      for (const heading of headings) observer.observe(heading);
      setActive(tocTargetId(headings[0]));
    } else if (headings.length) {
      const firstLink = tocList.querySelector("a");
      if (firstLink) firstLink.classList.add("is-active");
    }
    syncTocVisibility = () => {
      const visibleHeadings = headings.filter((heading) => !heading.closest("[hidden]"));
      const visibleIds = new Set(visibleHeadings.map(tocTargetId));
      for (const list of [tocList, mobileTocList]) {
        if (!list) continue;
        for (const link of list.querySelectorAll("[data-toc-target]")) {
          link.closest("li").hidden = !visibleIds.has(link.dataset.tocTarget);
        }
      }
      const active = tocList.querySelector(".is-active");
      if (active && !visibleIds.has(active.dataset.tocTarget)) {
        active.classList.remove("is-active");
        if (visibleHeadings.length) updateActiveToc(tocTargetId(visibleHeadings[0]));
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
    // Textarea selection normalizes CRLF. Supply the bound original to the
    // real copy event instead of publishing that normalized selection.
    const preserveOriginal = (event) => {
      if (event.clipboardData) {
        event.clipboardData.setData("text/plain", value);
        event.preventDefault();
      }
    };
    document.addEventListener("copy", preserveOriginal);
    try { copied = document.execCommand("copy"); } catch (_) { copied = false; }
    finally { document.removeEventListener("copy", preserveOriginal); area.remove(); }
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
      const original = code.getAttribute("data-cjdoc-source");
      const copied = await copyText(original === null ? (code.textContent || "") : JSON.parse(original));
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
  // Member actions are outside native <details>, so they work while collapsed.
  // On devices without a reliable hover state, a small disclosure keeps them discoverable.
  const memberActionBars = [...document.querySelectorAll("[data-cjdoc-member-actions]")];
  const closeMemberActionBars = (restoreFocus = false) => {
    for (const actions of memberActionBars) {
      if (actions.dataset.open !== "true") continue;
      actions.dataset.open = "false";
      actions.closest(".member-row")?.classList.remove("member-actions-open");
      const toggle = actions.querySelector("[data-cjdoc-member-actions-toggle]");
      if (toggle) {
        toggle.setAttribute("aria-expanded", "false");
        if (restoreFocus) toggle.focus();
      }
    }
  };
  for (const actions of memberActionBars) {
    const toggle = actions.querySelector("[data-cjdoc-member-actions-toggle]");
    if (!toggle) continue;
    toggle.addEventListener("click", () => {
      const opening = actions.dataset.open !== "true";
      closeMemberActionBars();
      if (!opening) return;
      actions.dataset.open = "true";
      toggle.setAttribute("aria-expanded", "true");
      actions.closest(".member-row")?.classList.add("member-actions-open");
    });
    actions.addEventListener("keydown", (event) => {
      if (event.key !== "Escape" || actions.dataset.open !== "true") return;
      event.preventDefault();
      closeMemberActionBars(true);
    });
    actions.addEventListener("focusout", (event) => {
      if (!actions.contains(event.relatedTarget)) closeMemberActionBars();
    });
    // Enable the compact menu only after listeners are wired. Without JS the
    // native links remain visible in the normal document flow.
    actions.closest(".member-row")?.classList.add("member-actions-enhanced");
  }
  document.addEventListener("pointerdown", (event) => {
    if (!event.target.closest?.("[data-cjdoc-member-actions]")) closeMemberActionBars();
  });

  const memberFilter = document.querySelector("[data-cjdoc-member-filter]");
  const originFilter = document.querySelector("[data-cjdoc-member-origin]");
  const memberFilterToggle = document.querySelector("[data-cjdoc-member-filter-toggle]");
  const memberFilterFields = document.querySelector(".member-filter-fields");
  if (memberFilterToggle && memberFilterFields) {
    memberFilterToggle.addEventListener("click", () => {
      const opening = memberFilterToggle.getAttribute("aria-expanded") !== "true";
      memberFilterToggle.setAttribute("aria-expanded", String(opening));
      memberFilterFields.classList.toggle("is-open", opening);
      if (opening) memberFilter?.focus();
    });
    memberFilterToggle.hidden = false;
    memberFilterToggle.closest(".member-browser")?.classList.add("member-browser-enhanced");
  }
  const memberRows = [...document.querySelectorAll("[data-cjdoc-member]")];
  const expandableMemberRows = memberRows.filter((member) => member.tagName === "DETAILS");
  // Ordinary overload groups pay extra layout cost without a large-page gain.
  // Reuse the existing navigation cap as the large member-browser boundary.
  if (memberRows.length > 256) {
    memberFilter?.closest(".member-browser")?.classList.add("member-browser-large");
  }
  const memberGroups = [...document.querySelectorAll("[data-cjdoc-member-group]")];
  const overloadGroups = [...document.querySelectorAll("[data-cjdoc-overload-group]")];
  const memberStatus = document.querySelector("[data-cjdoc-member-filter-status]");
  const expandMembers = document.querySelector("[data-cjdoc-members-expand]");
  const collapseMembers = document.querySelector("[data-cjdoc-members-collapse]");
  const syncMemberActions = () => {
    const visible = expandableMemberRows.filter((member) => !member.hidden);
    if (expandMembers) expandMembers.disabled = !visible.some((member) => !member.open);
    if (collapseMembers) collapseMembers.disabled = !visible.some((member) => member.open);
  };
  let memberTargetNotice = "";
  const applyMemberFilter = () => {
    closeMemberActionBars();
    const query = memberFilter ? memberFilter.value.trim().toLocaleLowerCase() : "";
    const origin = originFilter ? originFilter.value : "";
    if (memberFilterToggle) {
      const count = Number(Boolean(query)) + Number(Boolean(origin));
      memberFilterToggle.textContent = (isChinese ? "筛选成员" : "Filter members") +
        (count ? " (" + count + ")" : "");
    }
    let visible = 0;
    for (const row of memberRows) {
      const haystack = (row.dataset.memberName || "") + " " +
        (row.dataset.memberKind || "") + " " + (row.textContent || "");
      const queryMatches = !query || haystack.toLocaleLowerCase().includes(query);
      const originMatches = !origin || row.dataset.memberOrigin === origin;
      const matches = queryMatches && originMatches;
      row.hidden = !matches;
      const memberRow = row.closest(".member-row");
      if (memberRow) memberRow.hidden = !matches;
      if (matches) visible += 1;
    }
    // Group boundaries remain in the DOM while filtering, but never leave
    // empty visual cards or claim that all overloads matched the filter.
    for (const group of overloadGroups) {
      const matches = [...group.querySelectorAll(":scope > .member-row > [data-cjdoc-member]")]
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
      const members = [...group.querySelectorAll("[data-cjdoc-member]")];
      const matches = members.filter((member) => !member.hidden).length;
      group.hidden = matches === 0;
      const label = group.querySelector(".member-group-count");
      if (label) {
        const count = matches === members.length ? members.length : matches + " / " + members.length;
        label.textContent = count + (isChinese ? " 个成员" : " members");
      }
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
    return "cjdoc-member-state:" + [project, version, document.documentElement.lang, audience, cfg, location.pathname].join("|");
  })();
  const navigationEntry = performance.getEntriesByType("navigation")[0];
  const isHistoryNavigation = navigationEntry && navigationEntry.type === "back_forward";
  // Document scroll belongs to native history restoration; its old stored copy
  // had no reader. Cache only the sidebar offset that this script restores.
  let sidebarScrollTop = 0;
  if (sidebar) sidebar.addEventListener("scroll", () => {
    sidebarScrollTop = sidebar.scrollTop;
  }, {passive: true});
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
        sidebar: sidebarScrollTop
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
      for (const item of expandableMemberRows) item.open = state.open.includes(item.id);
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
  for (const member of expandableMemberRows) member.addEventListener("toggle", () => {
    syncMemberActions();
    saveMemberState();
  });
  for (const [button, open] of [[expandMembers, true], [collapseMembers, false]]) {
    if (button) button.addEventListener("click", () => {
      for (const member of expandableMemberRows) if (!member.hidden) member.open = open;
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
    if (member) {
      if (member.hidden) {
        if (memberFilter) memberFilter.value = "";
        if (originFilter) originFilter.value = "";
        memberTargetNotice = isChinese
          ? "；已清除筛选以显示链接目标。"
          : ". Filters cleared to reveal the linked member.";
        applyMemberFilter();
      }
      member.hidden = false;
      if (member.tagName === "DETAILS") member.open = true;
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
  window.addEventListener("pagehide", () => {
    // Navigation may happen before a queued scroll event, so take a final snapshot.
    sidebarScrollTop = sidebar ? sidebar.scrollTop : 0;
    saveMemberState();
  });
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
