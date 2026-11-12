package cjdoc.render

internal let HTML_THEME_BOOTSTRAP_SCRIPT = """
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
      return value && typeof value === "object" ? value : {};
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

internal let HTML_SEARCH_CONTROLLER_SCRIPT = """
(() => {
  const kernel = globalThis.cjdocSearch;
  const index = globalThis.__CJDOC_SEARCH_INDEX__;
  const dialog = document.querySelector("[data-cjdoc-search-dialog]");
  const trigger = document.querySelector("[data-cjdoc-search-trigger]");
  const input = document.querySelector("[data-cjdoc-search]");
  const results = document.querySelector("[data-cjdoc-results]");
  const closeButton = document.querySelector("[data-cjdoc-search-close]");
  if (!dialog || !input || !results) return;
  const isChinese = (document.documentElement.lang || "").toLowerCase().startsWith("zh");
  const kindLabels = {function: "函数", constructor: "构造器", property: "属性", variable: "变量",
    class: "类", struct: "结构体", interface: "接口", enum: "枚举", enumCase: "枚举项",
    extend: "扩展", typeAlias: "类型别名", concept: "指南", macro: "宏"};
  const englishKindLabels = {typeAlias: "type alias", enumCase: "enum case", extend: "extension"};
  const kindLabel = value => isChinese ? (kindLabels[value] || value) : (englishKindLabels[value] || value);
  const root = input.dataset.root || "";
  const kindFilter = document.querySelector("[data-cjdoc-kind]");
  const packageFilter = document.querySelector("[data-cjdoc-package]");
  const searchStatus = document.querySelector("[data-cjdoc-search-status]");
  const searchPages = document.querySelector("[data-cjdoc-search-pages]");
  const previousPage = document.querySelector("[data-cjdoc-search-previous]");
  const nextPage = document.querySelector("[data-cjdoc-search-next]");
  const searchFacets = document.querySelector("[data-cjdoc-search-facets]");
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
  let composing = false;

  const initSearchDialog = () => {
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
        value.property === property ||
        (Array.isArray(value.property) && value.property.includes(property)));
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

    const showError = (code, token = "") => {
      if (!searchStatus) return;
      const detail = token ? " “" + token + "”" : "";
      searchStatus.textContent = (isChinese ? "搜索错误 (" : "Search error (") + code + ")" + detail;
      searchStatus.hidden = false;
    };
    const selectedFacetTags = (tags, id) => {
      const active = new Set(tags);
      if (active.has(id)) active.delete(id);
      else active.add(id);
      return [...active].sort(kernel.compareBytes);
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
        const button = document.createElement("button");
        button.type = "button";
        button.className = "cj-search__facet";
        button.setAttribute("data-cjdoc-search-facet", "");
        button.setAttribute("data-cjdoc-tag-id", facet.id);
        button.setAttribute("data-cjdoc-facet-module-id", facet.scope.moduleId);
        button.setAttribute("data-cjdoc-facet-snapshot-id", facet.scope.snapshotId);
        button.setAttribute("aria-pressed",
          activeTags.includes(facet.id) ? "true" : "false");
        button.textContent = facet.scope.moduleId + " · " + facet.title + " [" + facet.id +
          "] (" + facet.count + ")";
        button.addEventListener("click", () => toggleFacet(facet));
        searchFacets.append(button);
      }
      searchFacets.hidden = rows.length === 0;
    };
    const toggleFacet = facet => {
      if (!currentRequest) return;
      const tags = selectedFacetTags(currentRequest.tags || [], facet.id);
      // The URL owns the toggled tag set; typed predicates must not restore a
      // removed tag on the next input event. Preserve all non-tag input tokens.
      input.value = input.value.split(/[ \\t\\n\\r\\f\\v]+/u)
        .filter(token => token && kernel.fold(token.slice(0, 4)) !== "tag:").join(" ");
      urlSearchState.tags = tags;
      urlSearchState.moduleId = facet.scope.moduleId;
      urlSearchState.snapshotId = facet.scope.snapshotId;
      urlSearchState.hasScope = true;
      urlSearchState.errorCode = null;
      try {
        const url = new URL(window.location.href);
        url.searchParams.delete("tag");
        for (const tag of tags) url.searchParams.append("tag", tag);
        url.searchParams.set("moduleId", facet.scope.moduleId);
        url.searchParams.set("snapshotId", facet.scope.snapshotId);
        window.history.pushState({}, "", url.href);
      } catch (_) { /* history can be unavailable */ }
      render();
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
      for (let position = 0; position < results.children.length; position += 1) {
        results.children[position].setAttribute("aria-selected",
          position === selected ? "true" : "false");
      }
      const active = results.children[selected];
      if (!active) { input.removeAttribute("aria-activedescendant"); return; }
      input.setAttribute("aria-activedescendant", active.id);
      if (typeof active.scrollIntoView === "function") active.scrollIntoView({block: "nearest"});
    };

    const appendHitField = (parent, text) => {
      const field = document.createElement("span");
      field.className = "cj-search__hit-field";
      field.textContent = text;
      parent.append(field);
    };
    const createHit = (entry, match, bodyText, section, signatures) => {
      const item = document.createElement("li");
      item.className = "cj-search__hit";
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", "false");
      const link = document.createElement("a");
      link.className = "cj-search__hit-link";
      link.setAttribute("href", root + entry.href + (section ? "#" + section.anchor : ""));
      const head = document.createElement("span");
      head.className = "cj-search__hit-head";
      const name = document.createElement("span");
      name.className = "cj-search__hit-name";
      name.textContent = entry.name || entry.summaryDisplay || "";
      const kind = document.createElement("span");
      kind.className = "cj-kind";
      kind.setAttribute("data-kind", String(entry.kind));
      kind.textContent = kindLabel(entry.kind);
      head.append(name, kind);
      link.append(head);
      const module = entry.scope >= 0 ? index.modules[entry.scope] : null;
      const moduleName = module ? module.moduleName : "";
      const ownerLabel = entry.ownerName || entry.packageName || "";
      const moduleLabel = moduleName && moduleName !== entry.packageName ? moduleName : "";
      const context = document.createElement("span");
      context.className = "cj-search__hit-context";
      context.textContent = [ownerLabel, moduleLabel].filter(Boolean).join(" · ");
      context.setAttribute("title",
        [entry.qualifiedName, moduleName, module ? module.moduleId : ""].filter(Boolean).join(" · "));
      link.append(context);
      const signatureText = signatures[entry.id] || signatures[entry.canonicalId] || "";
      if (signatureText) {
        const signature = document.createElement("code");
        signature.className = "cj-search__hit-signature";
        signature.textContent = signatureText;
        link.append(signature);
      }
      if (entry.summaryDisplay) {
        const summary = document.createElement("span");
        summary.className = "cj-search__hit-summary";
        summary.textContent = entry.summaryDisplay;
        link.append(summary);
      }
      if (bodyText) {
        const line = document.createElement("span");
        line.className = "cj-search__hit-body";
        if (match.reason === "documentation_text" || match.reason === "guide_text") {
          appendHitField(line, (isChinese ? "正文" : "Body text") + " ");
        }
        line.append(document.createTextNode(bodyText));
        link.append(line);
      }
      item.append(link);
      return item;
    };

    const renderPage = () => {
      results.replaceChildren();
      selected = -1;
      input.removeAttribute("aria-activedescendant");
      visible = [];
      if (searchFacets) { searchFacets.replaceChildren(); searchFacets.hidden = true; }
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
        const hit = createHit(entry, match, bodyText, matchedSection(entry, match), signatures);
        hit.id = "cjdoc-search-result-" + results.children.length;
        results.append(hit);
        visible.push(match);
      }
      renderTagFacets(currentExecution);
      const start = currentExecution.offset;
      const returned = currentExecution.returned;
      if (searchStatus) {
        searchStatus.textContent = !currentExecution.total
          ? currentExecution.status === "source_incomplete"
            ? (isChinese ? "API 收集不完整；未找到匹配项。"
              : "API collection is incomplete; no match found.")
            : (isChinese ? "此索引中没有匹配项。" : "No matches in this index.")
          : (isChinese ? "显示 " : "Showing ") + (start + 1) + "–" + (start + returned) +
            (isChinese ? " 项，共 " : " of ") + currentExecution.total +
            (isChinese ? " 项。" : " matches.");
        searchStatus.hidden = false;
      }
      if (searchPages) searchPages.hidden = !cursorHistory.length && !currentExecution.next;
      if (previousPage) previousPage.disabled = cursorHistory.length === 0;
      if (nextPage) nextPage.disabled = !currentExecution.next;
      input.setAttribute("aria-expanded", visible.length ? "true" : "false");
    };

    const resetSearch = () => {
      visible = [];
      selected = -1;
      results.replaceChildren();
      input.removeAttribute("aria-activedescendant");
      input.setAttribute("aria-expanded", "false");
      if (searchStatus) searchStatus.hidden = true;
      if (searchPages) searchPages.hidden = true;
      if (searchFacets) { searchFacets.replaceChildren(); searchFacets.hidden = true; }
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

    const capability = kernel && index ? kernel.execute(index, {
      operation: "search", mode: "discovery", profile: "bounded-static", query: "", limit: 0
    }) : null;
    const indexCapabilityError = capability && capability.errorCode ? capability.errorCode :
      (!kernel || !index ? "search_index_unavailable" : null);

    const render = () => {
      resetSearch();
      if (!kernel || !index) { showError("search_index_unavailable"); return; }
      if (urlSearchState.errorCode) {
        showError(urlSearchState.errorCode, urlSearchState.invalidToken);
        return;
      }
      if (indexCapabilityError) { showError(indexCapabilityError); return; }
      const parsed = kernel.parseQuery(input.value, index.contract);
      if (parsed.errorCode) {
        showError(parsed.errorCode, parsed.invalidToken);
        return;
      }
      const selectedFiltersResult = selectedFilters();
      if (selectedFiltersResult.errorCode) {
        showError(selectedFiltersResult.errorCode);
        return;
      }
      const filters = parsed.filters.concat(selectedFiltersResult.filters);
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
        snapshotId: urlSearchState.snapshotId === null ? index.scope.snapshotId
          : urlSearchState.snapshotId,
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
      if (first && typeof first.focus === "function") first.focus();
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
    if (kernel && index && !indexCapabilityError) {
      addOptions(kindFilter, entries.map(entry => entry.kind), kindLabel);
      addOptions(packageFilter, entries.map(entry => entry.packageName));
    }
    render();

    const isComposing = event => composing || (event && event.isComposing === true);
    input.addEventListener("compositionstart", () => { composing = true; });
    input.addEventListener("compositionend", () => { composing = false; render(); });
    input.addEventListener("input", event => { if (isComposing(event)) return; render(); });
    if (kindFilter) kindFilter.addEventListener("change", render);
    if (packageFilter) packageFilter.addEventListener("change", render);

    const focusTarget = () => {
      if (input && typeof input.focus === "function") input.focus();
      if (input && typeof input.select === "function") input.select();
    };
    const openDialog = () => {
      if (trigger) trigger.setAttribute("aria-expanded", "true");
      if (typeof dialog.showModal === "function" && !dialog.open) dialog.showModal();
      else dialog.setAttribute("open", "");
      render();
      focusTarget();
    };
    // Focus returns to the trigger only when the reader dismissed the dialog;
    // following a result leaves focus to the navigation target.
    let restoreFocusOnClose = true;
    const closeDialog = (restoreFocus = true) => {
      restoreFocusOnClose = restoreFocus;
      resetSearch();
      if (trigger) trigger.setAttribute("aria-expanded", "false");
      if (typeof dialog.close === "function" && dialog.open) dialog.close();
      else dialog.removeAttribute("open");
      if (restoreFocus && trigger && typeof trigger.focus === "function") trigger.focus();
    };
    if (trigger) {
      trigger.hidden = false;
      trigger.addEventListener("click", openDialog);
    }
    if (closeButton) closeButton.addEventListener("click", () => closeDialog(true));
    dialog.addEventListener("close", () => {
      if (trigger) trigger.setAttribute("aria-expanded", "false");
      resetSearch();
      if (restoreFocusOnClose && trigger && typeof trigger.focus === "function") trigger.focus();
      restoreFocusOnClose = true;
    });
    dialog.addEventListener("click", event => {
      // A click on the dialog element itself is the backdrop area.
      if (event.target === dialog) { closeDialog(true); return; }
      // A same-document result only changes the fragment, so the modal would
      // otherwise stay over its own destination. Modified clicks open elsewhere.
      const link = event.target && event.target.closest ? event.target.closest("a[href]") : null;
      if (!link || !results.contains(link)) return;
      if (event.button || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
      closeDialog(false);
    });

    const typingElsewhere = event => {
      const target = event.target;
      if (!target) return false;
      const tag = String(target.tagName || "").toLowerCase();
      return tag === "input" || tag === "textarea" || tag === "select" || target.isContentEditable;
    };
    document.addEventListener("keydown", event => {
      const isSearchKey = ((event.ctrlKey || event.metaKey) &&
        event.key.toLocaleLowerCase() === "k") ||
        (event.key === "/" && !typingElsewhere(event));
      if (!isSearchKey) return;
      event.preventDefault();
      if (!dialog.open) openDialog();
      else focusTarget();
    });
    input.addEventListener("keydown", event => {
      // Escape stays usable mid-composition; navigation and activation do not.
      if (event.key === "Escape") {
        event.preventDefault();
        closeDialog(true);
        return;
      }
      if (isComposing(event)) return;
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        const focused = event.target.closest && event.target.closest('[role="option"]');
        const position = focused ? Array.prototype.indexOf.call(results.children, focused) : -1;
        const active = position >= 0 ? position : selected;
        select(event.key === "ArrowDown" ? active + 1 : active < 0 ? visible.length - 1 : active - 1);
      } else if (event.key === "Enter" && selected >= 0) {
        const entry = results.children[selected];
        const link = entry && entry.querySelector("a");
        if (link) { event.preventDefault(); link.click(); }
      }
    });
    // A tag badge or shared link lands here with ?tag/moduleId/snapshotId; the
    // reader asked for those results, so show them instead of a closed dialog.
    const urlRequestsSearch = () => urlSearchState.tags.length > 0 ||
      urlSearchState.hasScope || urlSearchState.errorCode !== null;
    if (urlRequestsSearch()) openDialog();
    window.addEventListener("popstate", () => {
      Object.assign(urlSearchState, readUrlSearchState());
      cursorHistory = [];
      if (urlRequestsSearch() && !dialog.open) openDialog();
      else render();
    });
  };

  initSearchDialog();
})();
"""

// search.js order is fixed by renderers_output.cj:
// sidebar navigation + search kernel + this dialog controller + reading
// controllers + language navigation.
internal let HTML_SEARCH_SCRIPT = HTML_SEARCH_KERNEL_SCRIPT + HTML_SEARCH_CONTROLLER_SCRIPT +
    HTML_READING_SCRIPT
