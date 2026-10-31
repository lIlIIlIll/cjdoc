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

internal let HTML_SEARCH_SCRIPT = HTML_SEARCH_KERNEL_SCRIPT + """
(() => {
  const publishedSearchIndex = globalThis.__CJDOC_SEARCH_INDEX__;
  const publishedSearchKernel = globalThis.cjdocSearch;
  const input = document.querySelector("[data-cjdoc-search]");
  const results = document.querySelector("[data-cjdoc-results]");
  const isChinese = (document.documentElement.lang || "").toLowerCase().startsWith("zh");
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
  const searchFacets = document.querySelector("[data-cjdoc-search-facets]");
  const index = publishedSearchIndex;
  const kernel = publishedSearchKernel;
  const pageSize = index && index.contract && Number.isSafeInteger(index.contract.defaultLimit)
    ? index.contract.defaultLimit : 0;
  const entries = index && Array.isArray(index.entries) ? index.entries : [];
  let visible = [];
  let selected = -1;
  let currentRequest = null;
  let currentCursor = null;
  let cursorHistory = [];
  let currentExecution = null;
  let currentParsed = null;
  const readUrlSearchState = () => {
    const state = {tags: [], moduleId: null, snapshotId: null, hasScope: false,
      errorCode: null, invalidToken: ""};
    const search = window.location && typeof window.location.search === "string"
      ? window.location.search : "";
    if (!search) return state;
    if (typeof URLSearchParams !== "function") {
      state.errorCode = "request_schema";
      return state;
    }
    let params;
    try { params = new URLSearchParams(search); }
    catch (_) { state.errorCode = "request_schema"; return state; }
    const tags = params.getAll("tag");
    if (tags.length > 64) {
      state.errorCode = "request_schema";
      state.invalidToken = "tag";
      return state;
    }
    if (kernel && index && index.contract) {
      for (const tag of tags) {
        const parsed = kernel.parseQuery("tag:" + tag, index.contract);
        if (parsed.errorCode) {
          state.errorCode = parsed.errorCode;
          state.invalidToken = parsed.invalidToken || "tag:" + tag;
          return state;
        }
      }
    }
    const modules = params.getAll("moduleId");
    const snapshots = params.getAll("snapshotId");
    if (modules.length > 1 || snapshots.length > 1) {
      state.errorCode = "request_schema";
      state.invalidToken = modules.length > 1 ? "moduleId" : "snapshotId";
      return state;
    }
    state.tags = tags;
    if (modules.length) { state.moduleId = modules[0]; state.hasScope = true; }
    if (snapshots.length) { state.snapshotId = snapshots[0]; state.hasScope = true; }
    return state;
  };
  const urlSearchState = readUrlSearchState();
  const filterFieldForProperty = property => {
    const rows = index && index.contract && Array.isArray(index.contract.filterFields) ?
      index.contract.filterFields : [];
    const row = rows.find(value =>
      value.property === property || (Array.isArray(value.property) && value.property.includes(property)));
    return row ? row.field : null;
  };
  const filterOpForPrimitive = primitive => {
    const rows = index && index.contract && Array.isArray(index.contract.filterOps) ?
      index.contract.filterOps : [];
    const row = rows.find(value => value.primitive === primitive);
    return row ? row.op : null;
  };
  const selectedFilters = () => {
    const filters = [];
    const op = filterOpForPrimitive("exact_string_equal");
    if (packageFilter && packageFilter.value) {
      const field = filterFieldForProperty("packageName");
      if (!field || !op) return {filters: [], errorCode: "search_contract_unsupported"};
      filters.push({field, op, value: packageFilter.value});
    }
    if (kindFilter && kindFilter.value) {
      const field = filterFieldForProperty("kind");
      if (!field || !op) return {filters: [], errorCode: "search_contract_unsupported"};
      filters.push({field, op, value: kindFilter.value});
    }
    return {filters, errorCode: null};
  };
  const blankSearch = value => /^[ \\t\\n\\r\\f\\v]*$/u.test(value);
  const showError = (code, token = "") => {
    if (searchStatus) {
      const detail = token ? " “" + token + "”" : "";
      searchStatus.textContent = (isChinese ? "搜索错误 (" : "Search error (") + code + ")" + detail;
      searchStatus.hidden = false;
    }
    if (searchPopover) searchPopover.hidden = false;
  };
  const selectedFacetTags = (tags, id) => {
    const active = new Set(tags);
    if (active.has(id)) active.delete(id);
    else active.add(id);
    return [...active].sort(kernel.compareBytes);
  };
  const tagFacetHref = (tags, moduleId, snapshotId) => {
    const query = [];
    for (const tag of tags) query.push("tag=" + encodeURIComponent(tag));
    query.push("moduleId=" + encodeURIComponent(moduleId));
    query.push("snapshotId=" + encodeURIComponent(snapshotId));
    return root + "index.html?" + query.join("&");
  };
  const renderTagFacets = execution => {
    if (!searchFacets) return;
    const rows = execution.facets && Array.isArray(execution.facets.tags)
      ? execution.facets.tags : null;
    searchFacets.replaceChildren();
    searchFacets.hidden = true;
    if (!rows) { showError("search_index_invalid"); return; }
    const activeTags = currentRequest && Array.isArray(currentRequest.tags)
      ? currentRequest.tags : urlSearchState.tags;
    for (const facet of rows) {
      if (!facet || !facet.scope || typeof facet.scope.moduleId !== "string" ||
          typeof facet.scope.snapshotId !== "string" || typeof facet.id !== "string" ||
          typeof facet.title !== "string" || !Number.isSafeInteger(facet.count)) {
        showError("search_index_invalid");
        searchFacets.replaceChildren();
        return;
      }
      const isSelected = activeTags.includes(facet.id);
      const tags = selectedFacetTags(activeTags, facet.id);
      const link = document.createElement("a");
      link.className = isSelected ? "search-facet is-selected" : "search-facet";
      link.href = tagFacetHref(tags, facet.scope.moduleId, facet.scope.snapshotId);
      link.setAttribute("data-cjdoc-search-facet", "");
      link.setAttribute("data-cjdoc-tag-id", facet.id);
      link.setAttribute("data-cjdoc-facet-module-id", facet.scope.moduleId);
      link.setAttribute("data-cjdoc-facet-snapshot-id", facet.scope.snapshotId);
      if (isSelected) link.setAttribute("aria-current", "true");
      link.textContent = facet.scope.moduleId + " · " + facet.title + " [" + facet.id + "] (" + facet.count + ")";
      searchFacets.append(link);
    }
    searchFacets.hidden = rows.length === 0;
  };
  const bodySnippet = (text, term) => {
    const folded = kernel.fold(text);
    const at = folded.indexOf(term);
    if (at < 0) return text.slice(0, 120);
    const from = Math.max(0, at - 12);
    const to = Math.min(text.length, at + term.length + 48);
    return (from > 0 ? "…" : "") + text.slice(from, to) + (to < text.length ? "…" : "");
  };
  const matchedBodySnippet = (entry, item, parsed) => {
    if (!entry.body || (item.reason !== "documentation_text" && item.reason !== "guide_text")) return null;
    const terms = kernel.tokens(parsed.query);
    if (!terms.length) return null;
    const body = kernel.fold(entry.body);
    if (!terms.every(term => body.includes(term))) return null;
    return bodySnippet(entry.body, terms[0]);
  };
  const matchedSection = (entry, item) => {
    if (!item.anchor || !Array.isArray(entry.sections)) return null;
    return entry.sections.find(section => section.anchor === item.anchor) || null;
  };
  const select = next => {
    if (!visible.length) return;
    selected = (next + visible.length) % visible.length;
    for (let index = 0; index < results.children.length; index += 1) {
      results.children[index].setAttribute("aria-selected", index === selected ? "true" : "false");
    }
    const active = results.children[selected];
    if (!active) { input.removeAttribute("aria-activedescendant"); return; }
    input.setAttribute("aria-activedescendant", active.id);
    active.scrollIntoView({block: "nearest"});
  };
  const renderPage = () => {
    results.replaceChildren();
    selected = -1;
    input.removeAttribute("aria-activedescendant");
    visible = [];
    if (searchFacets) {
      searchFacets.replaceChildren();
      searchFacets.hidden = true;
    }
    if (!currentExecution) return;
    if (currentExecution.errorCode) {
      showError(currentExecution.errorCode);
      if (searchPages) searchPages.hidden = true;
      return;
    }
    const signatures = globalThis.__CJDOC_SEARCH_SIGNATURES__ || {};
    for (const match of currentExecution.items) {
      const entry = kernel.findEntry(index, match.snapshotId, match.canonicalId);
      if (!entry) {
        showError("search_index_invalid");
        results.replaceChildren();
        visible = [];
        return;
      }
      const bodyText = matchedBodySnippet(entry, match, currentParsed);
      const section = matchedSection(entry, match);
      const fieldLabel = match.reason === "documentation_text" || match.reason === "guide_text"
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
      name.textContent = entry.name || entry.summaryDisplay || "";
      kind.className = "search-kind";
      kind.textContent = kindLabel(entry.kind);
      context.className = "search-context";
      const ownerLabel = entry.ownerName || entry.packageName || "";
      const module = entry.scope >= 0 ? index.modules[entry.scope] : null;
      const moduleName = module ? module.moduleName : "";
      const moduleId = module ? module.moduleId : "";
      const moduleLabel = moduleName && moduleName !== entry.packageName ? moduleName : "";
      context.textContent = [ownerLabel, moduleLabel].filter(Boolean).join(" · ");
      context.title = [entry.qualifiedName, moduleName, moduleId].filter(Boolean).join(" · ");
      head.append(name, kind);
      link.append(head, context);
      const signatureText = signatures[entry.id] || signatures[entry.canonicalId] || "";
      if (signatureText) {
        signature.className = "search-result-signature";
        signature.textContent = signatureText;
        link.append(signature);
      }
      if (entry.summaryDisplay) {
        summary.className = "search-summary";
        summary.textContent = entry.summaryDisplay;
        link.append(summary);
      }
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
      visible.push(match);
    }
    renderTagFacets(currentExecution);
    const start = currentExecution.offset;
    const returned = currentExecution.returned;
    if (searchStatus) {
      searchStatus.textContent = !currentExecution.total
        ? currentExecution.status === "source_incomplete"
          ? (isChinese ? "API 收集不完整；未找到匹配项。" : "API collection is incomplete; no match found.")
          : (isChinese ? "此索引中没有匹配项。" : "No matches in this index.")
        : (isChinese ? "显示 " : "Showing ") + (start + 1) + "–" + (start + returned) +
          (isChinese ? " 项，共 " : " of ") + currentExecution.total + (isChinese ? " 项。" : " matches.");
      searchStatus.hidden = false;
    }
    if (searchPages) searchPages.hidden = !cursorHistory.length && !currentExecution.next;
    if (previousPage) previousPage.disabled = cursorHistory.length === 0;
    if (nextPage) nextPage.disabled = !currentExecution.next;
    if (searchPopover) searchPopover.hidden = false;
    input.setAttribute("aria-expanded", visible.length ? "true" : "false");
  };
  const closeSearch = () => {
    visible = [];
    selected = -1;
    results.replaceChildren();
    input.removeAttribute("aria-activedescendant");
    input.setAttribute("aria-expanded", "false");
    if (searchStatus) searchStatus.hidden = true;
    if (searchPages) searchPages.hidden = true;
    if (searchFacets) searchFacets.hidden = true;
    if (searchPopover) searchPopover.hidden = true;
  };
  const resetSearch = () => {
    closeSearch();
    currentRequest = null;
    currentExecution = null;
    currentParsed = null;
    currentCursor = null;
    cursorHistory = [];
  };
  const runPage = cursor => {
    if (!currentRequest) return;
    const request = {...currentRequest};
    if (cursor) request.cursor = cursor;
    currentCursor = cursor || null;
    currentExecution = kernel.execute(index, request);
    renderPage();
  };
  const render = () => {
    resetSearch();
    const rawQuery = input.value;
    if (!kernel || !index) {
      showError("search_index_unavailable");
      return;
    }
    if (urlSearchState.errorCode) {
      showError(urlSearchState.errorCode, urlSearchState.invalidToken);
      return;
    }
    if (indexCapabilityError) {
      showError(indexCapabilityError);
      return;
    }
    const parsed = kernel.parseQuery(rawQuery, index.contract);
    if (parsed.errorCode) {
      showError(parsed.errorCode, parsed.invalidToken);
      return;
    }
    const selected = selectedFilters();
    if (selected.errorCode) {
      showError(selected.errorCode);
      return;
    }
    const filters = parsed.filters.concat(selected.filters);
    const tags = parsed.tags.concat(urlSearchState.tags);
    if (!parsed.query && !filters.length && !tags.length && !urlSearchState.hasScope) return;
    currentParsed = parsed;
    currentRequest = {
      operation: "search",
      mode: "discovery",
      profile: "bounded-static",
      query: parsed.query,
      filters,
      limit: pageSize,
      snapshotId: urlSearchState.snapshotId === null ? index.scope.snapshotId : urlSearchState.snapshotId,
      language: index.scope.language,
      audience: index.scope.audience,
      cfgProfile: index.scope.cfgProfile
    };
    if (tags.length) currentRequest.tags = tags;
    if (urlSearchState.moduleId !== null) currentRequest.moduleId = urlSearchState.moduleId;
    runPage(null);
  };
  const changePage = direction => {
    if (!currentRequest || !currentExecution) return;
    if (direction > 0 && currentExecution.next) {
      cursorHistory.push(currentCursor);
      runPage(currentExecution.next);
    } else if (direction < 0 && cursorHistory.length) {
      runPage(cursorHistory.pop());
    } else return;
    const first = results.querySelector("a");
    if (first) first.focus();
    results.scrollTop = 0;
  };
  if (previousPage) previousPage.addEventListener("click", () => changePage(-1));
  if (nextPage) nextPage.addEventListener("click", () => changePage(1));
  const addOptions = (selectElement, values, display = value => value) => {
    if (!selectElement) return;
    const choices = values.filter(value => typeof value === "string" && value.trim() !== "");
    for (const value of [...new Set(choices)].sort(kernel.compareBytes)) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = display(value);
      selectElement.append(option);
    }
  };
  const capability = kernel && index ? kernel.execute(index, {
    operation: "search", mode: "discovery", profile: "bounded-static", query: "", limit: 0
  }) : null;
  const indexCapabilityError = capability && capability.errorCode ? capability.errorCode :
    (!kernel || !index ? "search_index_unavailable" : null);
  if (kernel && index && !indexCapabilityError) {
    addOptions(kindFilter, entries.map(entry => entry.kind), kindLabel);
    addOptions(packageFilter, entries.map(entry => entry.packageName));
  }
  render();
  let composing = false;
  const isComposing = event => composing || (event && event.isComposing === true);
  input.addEventListener("compositionstart", () => { composing = true; });
  input.addEventListener("compositionend", () => { composing = false; render(); });
  const hasActiveFilters = () => Boolean((kindFilter && kindFilter.value) ||
    (packageFilter && packageFilter.value) || urlSearchState.tags.length || urlSearchState.hasScope);
  const showSearch = () => {
    if ((blankSearch(input.value) && !hasActiveFilters()) || (searchPopover && !searchPopover.hidden)) return;
    if (currentExecution) renderPage();
    else render();
  };
  input.addEventListener("focus", showSearch);
  input.addEventListener("input", event => { if (isComposing(event)) return; render(); });
  if (kindFilter) kindFilter.addEventListener("change", render);
  if (packageFilter) packageFilter.addEventListener("change", render);
  (searchArea || input).addEventListener("keydown", (event) => {
    // Escape stays usable mid-composition; navigation and activation do not.
    if (event.key === "Escape") {
      input.value = "";
      event.preventDefault();
      if (event.target === input) input.blur();
      else input.focus();
      resetSearch();
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
  if (searchFacets) searchFacets.addEventListener("click", event => {
    const link = event.target.closest("a[data-cjdoc-search-facet]");
    if (!link || event.defaultPrevented || event.button !== 0 || event.metaKey ||
        event.ctrlKey || event.shiftKey || event.altKey || link.target === "_blank") return;
    const id = link.dataset.cjdocTagId;
    const moduleId = link.dataset.cjdocFacetModuleId;
    const snapshotId = link.dataset.cjdocFacetSnapshotId;
    if (!id || !moduleId || !snapshotId || !currentRequest) return;
    event.preventDefault();
    const tags = selectedFacetTags(currentRequest.tags || [], id);
    urlSearchState.tags = tags;
    urlSearchState.moduleId = moduleId;
    urlSearchState.snapshotId = snapshotId;
    urlSearchState.hasScope = true;
    urlSearchState.errorCode = null;
    if (tags.length) currentRequest.tags = tags;
    else delete currentRequest.tags;
    currentRequest.moduleId = moduleId;
    currentRequest.snapshotId = snapshotId;
    const url = new URL(window.location.href);
    url.searchParams.delete("tag");
    for (const tag of tags) url.searchParams.append("tag", tag);
    url.searchParams.set("moduleId", moduleId);
    url.searchParams.set("snapshotId", snapshotId);
    try { window.history.pushState({}, "", url.href); } catch (_) {}
    cursorHistory = [];
    runPage(null);
  });
  // Inspect original containment before a facet handler replaces its clicked DOM node.
  document.addEventListener("click", (event) => {
    if (searchArea && !searchArea.contains(event.target) && !event.target.closest(".search-filters") && !event.target.closest("[data-cjdoc-filter-toggle]")) closeSearch();
  }, true);
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
  window.addEventListener("popstate", () => {
    Object.assign(urlSearchState, readUrlSearchState());
    cursorHistory = [];
    render();
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
        role === "group" || role === "overload" ||
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
    const appendFlatItem = (heading, index, level) => {
      const item = document.createElement("li");
      item.dataset.depth = String(level);
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
      // The renderer records each member's real parent depth. A preceding
      // overload family is a sibling, not the parent of the next plain member.
      for (let index = 0; index < headings.length; index += 1) {
        const heading = headings[index];
        const role = heading.dataset.cjdocTocRole;
        const level = role === "member"
          ? Number(heading.dataset.cjdocTocDepth || 3)
          : Number(heading.tagName.slice(1));
        appendFlatItem(heading, index, level);
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
    const headingsByTarget = new Map(headings.map(heading => [tocTargetId(heading), heading]));
    syncTocVisibility = () => {
      const visibleHeadings = headings.filter((heading) => !heading.closest("[hidden]"));
      const visibleIds = new Set(visibleHeadings.map(tocTargetId));
      for (const list of [tocList, mobileTocList]) {
        if (!list) continue;
        for (const link of list.querySelectorAll("[data-toc-target]")) {
          link.closest("li").hidden = !visibleIds.has(link.dataset.tocTarget);
          const heading = headingsByTarget.get(link.dataset.tocTarget);
          if (heading && heading.dataset.cjdocTocRole !== "member") {
            const label = headingLabel(heading);
            if (link.textContent !== label) link.textContent = label;
          }
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
    const visible = memberRows.filter((member) => !member.hidden);
    if (expandMembers) expandMembers.disabled = !visible.some((member) => !member.open);
    if (collapseMembers) collapseMembers.disabled = !visible.some((member) => member.open);
  };
  let memberTargetNotice = "";
  const applyMemberFilter = () => {
    closeMemberActionBars();
    const rawQuery = memberFilter ? memberFilter.value : "";
    const origin = originFilter ? originFilter.value : "";
    const parsed = publishedSearchKernel && publishedSearchIndex
      ? publishedSearchKernel.parseQuery(rawQuery, publishedSearchIndex.contract)
      : {errorCode: "search_index_unavailable", query: "", filters: [], tags: []};
    let memberError = parsed.errorCode || null;
    let matchingIds = new Set();
    if (!memberError) {
      const localRequest = {query: parsed.query, filters: parsed.filters};
      if (parsed.tags.length) localRequest.tags = parsed.tags;
      const projection = publishedSearchKernel.filterEntries(publishedSearchIndex,
        localRequest, memberRows.map(row => row.dataset.memberSymbolId));
      if (projection.status !== "ok") memberError = projection.errorCode || "search_index_invalid";
      else matchingIds = new Set(projection.canonicalIds);
    }
    const queryActive = Boolean(parsed.query || parsed.filters.length || parsed.tags.length);
    if (memberFilterToggle) {
      const count = Number(queryActive) + Number(Boolean(origin));
      memberFilterToggle.textContent = (isChinese ? "筛选成员" : "Filter members") +
        (count ? " (" + count + ")" : "");
    }
    let visible = 0;
    for (const row of memberRows) {
      const canonicalId = row.dataset.memberSymbolId;
      const queryMatches = !memberError && matchingIds.has(canonicalId);
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
    // A group whose every member is filtered out must not leave an empty
    // section heading, an empty outer group, or a TOC entry behind.
    for (const role of document.querySelectorAll("[data-cjdoc-declaration-group]")) {
      const everything = [...role.querySelectorAll("[data-cjdoc-member]")];
      const matches = everything.filter((member) => !member.hidden).length;
      role.hidden = everything.length > 0 && matches === 0;
      const count = role.querySelector("[data-cjdoc-group-count]");
      if (count) {
        const total = Number(count.dataset.groupTotal);
        const value = matches === total ? String(total) : matches + " / " + total;
        count.textContent = isChinese ? "（" + value + "）" : " (" + value + ")";
      }
    }
    syncTocVisibility();
    syncMemberActions();
    if (memberStatus) {
      const active = Boolean(queryActive || origin || memberTargetNotice || memberError);
      if (!active) {
        memberStatus.hidden = true;
      } else if (memberError) {
        memberStatus.textContent = (isChinese ? "成员筛选错误：" : "Member filter error: ") + memberError;
        memberStatus.hidden = false;
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
