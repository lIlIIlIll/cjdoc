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

// The trigger carries the publication prefix before the lazy search dialog is built.
// One controller binds listeners per dialog. URL tag changes preserve other query tokens;
// incoming tag or snapshot links open the dialog rather than hiding the requested results.
internal let HTML_SEARCH_CONTROLLER_SCRIPT = """
(() => {
  const kernel = globalThis.cjdocSearch;
  const index = globalThis.__CJDOC_SEARCH_INDEX__;
  const trigger = document.querySelector("[data-cjdoc-search-trigger]");
  const isChinese = (document.documentElement.lang || "").toLowerCase().startsWith("zh");
  const text = (english, chinese) => isChinese ? chinese : english;
  const kindLabels = {__proto__: null, function: "函数", constructor: "构造器", property: "属性", variable: "变量",
    class: "类", struct: "结构体", interface: "接口", enum: "枚举", enumCase: "枚举项",
    extend: "扩展", typeAlias: "类型别名", concept: "指南", macro: "宏"};
  const englishKindLabels = {__proto__: null, typeAlias: "type alias", enumCase: "enum case", extend: "extension"};
  const kindLabel = value => isChinese ? (kindLabels[value] || value) : (englishKindLabels[value] || value);
  const root = trigger ? (trigger.dataset.cjdocRootPrefix || "") : "";
  const apiRoot = trigger ? (trigger.dataset.cjdocApiPrefix ?? root) : root;
  const createElement = (tag, className, content) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (content !== undefined) node.textContent = content;
    return node;
  };
  const createSearchIcon = () => {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    for (const [name, value] of [
      ["class", "cj-icon"], ["width", "16"], ["height", "16"], ["viewBox", "0 0 24 24"],
      ["fill", "none"], ["stroke", "currentColor"], ["stroke-width", "1.8"],
      ["stroke-linecap", "round"], ["stroke-linejoin", "round"],
      ["aria-hidden", "true"], ["focusable", "false"]
    ]) svg.setAttribute(name, value);
    const circle = document.createElementNS(svg.namespaceURI, "circle");
    for (const [name, value] of [["cx", "11"], ["cy", "11"], ["r", "7"]]) {
      circle.setAttribute(name, value);
    }
    const handle = document.createElementNS(svg.namespaceURI, "path");
    handle.setAttribute("d", "m20 20-4-4");
    svg.append(circle, handle);
    return svg;
  };
  const appendSearchFilter = (parent, property, labelText, allLabel) => {
    const row = createElement("label", "cj-search__filter");
    row.append(createElement("span", "cj-sr-only", labelText));
    const select = createElement("select", "cj-select");
    select.setAttribute(property, "");
    select.setAttribute("aria-label", labelText);
    const all = createElement("option", undefined, allLabel);
    all.setAttribute("value", "");
    select.append(all);
    row.append(select);
    parent.append(row);
    return select;
  };
  const buildSearchDialog = () => {
    const node = createElement("dialog", "cj-search");
    node.id = "cjdoc-search-dialog";
    node.setAttribute("data-cjdoc-search-dialog", "");
    node.setAttribute("aria-label", text("Search documentation", "搜索文档"));
    const bar = createElement("div", "cj-search__bar");
    bar.append(createSearchIcon());
    const fieldLabel = createElement("label", "cj-sr-only", text("Search API", "搜索 API"));
    fieldLabel.setAttribute("for", "cjdoc-search-input");
    bar.append(fieldLabel);
    const field = createElement("input", "cj-search__input");
    field.id = "cjdoc-search-input";
    field.setAttribute("type", "search");
    field.setAttribute("placeholder", text("Search docs", "搜索文档"));
    field.setAttribute("autocomplete", "off");
    field.setAttribute("role", "combobox");
    field.setAttribute("aria-autocomplete", "list");
    field.setAttribute("aria-controls", "cjdoc-search-results");
    field.setAttribute("aria-expanded", "false");
    field.setAttribute("data-cjdoc-search", "");
    field.setAttribute("data-root", root);
    bar.append(field);
    const close = createElement("button", "cj-button cj-button--quiet cj-search__close");
    close.setAttribute("type", "button");
    close.setAttribute("data-cjdoc-search-close", "");
    close.setAttribute("aria-label", text("Close search", "关闭搜索"));
    close.append(createElement("kbd", "cj-kbd", "Esc"));
    bar.append(close);
    node.append(bar);
    const filters = createElement("div", "cj-search__filters");
    filters.id = "cjdoc-search-filters";
    const kind = appendSearchFilter(filters, "data-cjdoc-kind",
      text("Filter by kind", "按类别筛选"), text("All kinds", "全部类别"));
    const pack = appendSearchFilter(filters, "data-cjdoc-package",
      text("Filter by package", "按包筛选"), text("All packages", "全部包"));
    node.append(filters);
    const facets = createElement("div", "cj-search__facets");
    facets.setAttribute("data-cjdoc-search-facets", "");
    facets.setAttribute("role", "group");
    facets.setAttribute("aria-label", text("Tag filters", "标签筛选"));
    facets.hidden = true;
    node.append(facets);
    const list = createElement("ul", "cj-search__results");
    list.id = "cjdoc-search-results";
    list.setAttribute("role", "listbox");
    list.setAttribute("data-cjdoc-results", "");
    list.setAttribute("aria-live", "polite");
    node.append(list);
    const status = createElement("p", "cj-search__status");
    status.setAttribute("data-cjdoc-search-status", "");
    status.setAttribute("role", "status");
    status.hidden = true;
    node.append(status);
    const pages = createElement("div", "cj-search__pages");
    pages.setAttribute("data-cjdoc-search-pages", "");
    pages.hidden = true;
    const previous = createElement("button", "cj-button", text("Previous", "上一页"));
    previous.setAttribute("type", "button");
    previous.setAttribute("data-cjdoc-search-previous", "");
    const next = createElement("button", "cj-button", text("Next", "下一页"));
    next.setAttribute("type", "button");
    next.setAttribute("data-cjdoc-search-next", "");
    pages.append(previous, next);
    node.append(pages);
    node.append(createElement("p", "cj-search__note", text(
      "Search covers names, structured fields and up to 2,000 characters of body text " +
        "per entry. No match does not prove absence from the full documentation.",
      "检索覆盖名称、结构化字段及每项最多 2,000 字符的正文摘录；没有命中不代表完整文档中不存在。")));
    return {node, field, close, list, status, pages, previous, next, facets, kind, pack};
  };
  let dialog = null;
  let input = null;
  let results = null;
  let closeButton = null;
  let kindFilter = null;
  let packageFilter = null;
  let searchStatus = null;
  let searchPages = null;
  let previousPage = null;
  let nextPage = null;
  let searchFacets = null;
  let controller = null;
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
  const urlRequestsSearch = () => urlSearchState.tags.length > 0 ||
    urlSearchState.hasScope || urlSearchState.errorCode !== null;
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

  const createController = () => {
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
        window.history.pushState(window.history.state, "", url.href);
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
      const destination = entry.concept ? root + entry.href
        : globalThis.__CJDOC_API_ROUTE__(apiRoot + encodeURI(entry.href));
      link.setAttribute("href", destination + (section ? "#" + section.anchor : ""));
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

    // Both a fresh render and a teardown start from the same empty state.
    const clearResults = () => {
      results.replaceChildren();
      selected = -1;
      visible = [];
      input.removeAttribute("aria-activedescendant");
      if (searchFacets) { searchFacets.replaceChildren(); searchFacets.hidden = true; }
    };
    const renderPage = () => {
      clearResults();
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
      clearResults();
      input.setAttribute("aria-expanded", "false");
      if (searchStatus) searchStatus.hidden = true;
      if (searchPages) searchPages.hidden = true;
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
    // Static selects used native history restoration. Deferred controls restore
    // only their selected filters, not the autocomplete-disabled query input.
    // Keep state on its history entry so repeated visits to one URL stay distinct.
    const navigation = typeof performance !== "undefined" &&
      performance.getEntriesByType ? performance.getEntriesByType("navigation")[0] : null;
    if (navigation && navigation.type === "back_forward") {
      try {
        const saved = window.history.state && window.history.state.cjdocSearchFilters;
        if (saved && typeof saved === "object") {
          for (const [control, key] of [[kindFilter, "kind"], [packageFilter, "package"]]) {
            const value = saved[key];
            if (control && typeof value === "string" &&
                Array.from(control.options).some(option => option.value === value)) {
              control.value = value;
            }
          }
        }
      } catch (_) { /* history can be unavailable */ }
    }
    const saveSelectedFilters = () => {
      try {
        const previous = window.history.state;
        const retained = previous && typeof previous === "object" && !Array.isArray(previous) ?
          previous : {};
        window.history.replaceState({...retained, cjdocSearchFilters: {
          kind: kindFilter ? kindFilter.value : "",
          package: packageFilter ? packageFilter.value : ""
        }}, "");
      } catch (_) { /* history can be unavailable */ }
    };
    const selectedFilterChanged = () => { saveSelectedFilters(); render(); };
    // Checkpoint the current search filters before leaving this history entry.
    window.addEventListener("pagehide", saveSelectedFilters);

    const isComposing = event => composing || (event && event.isComposing === true);
    input.addEventListener("compositionstart", () => { composing = true; });
    input.addEventListener("compositionend", () => { composing = false; render(); });
    input.addEventListener("input", event => { if (isComposing(event)) return; render(); });
    if (kindFilter) kindFilter.addEventListener("change", selectedFilterChanged);
    if (packageFilter) packageFilter.addEventListener("change", selectedFilterChanged);

    const focusTarget = () => {
      if (input && typeof input.focus === "function") input.focus();
      if (input && typeof input.select === "function") input.select();
    };
    let returnTarget = trigger;
    const openDialog = () => {
      returnTarget = trigger;
      const settings = document.querySelector("[data-cjdoc-theme-popover]");
      if (settings && settings.open) {
        if (typeof settings.close === "function") settings.close();
        else settings.removeAttribute("open");
        returnTarget = document.querySelector("[data-cjdoc-theme-toggle]") || trigger;
        returnTarget?.setAttribute("aria-expanded", "false");
      }
      if (document.documentElement.dataset.cjDrawer === "open") {
        document.querySelector("[data-cjdoc-sidebar-close]")?.click();
      }
      if (trigger) trigger.setAttribute("aria-expanded", "true");
      render();
      if (typeof dialog.showModal === "function" && !dialog.open) dialog.showModal();
      else dialog.setAttribute("open", "");
      focusTarget();
    };
    // Dismissal returns to the invoking trigger; result navigation owns its focus.
    const closeDialog = (restoreFocus = true) => {
      resetSearch();
      if (trigger) trigger.setAttribute("aria-expanded", "false");
      if (typeof dialog.close === "function" && dialog.open) dialog.close();
      else dialog.removeAttribute("open");
      if (restoreFocus && returnTarget && typeof returnTarget.focus === "function") returnTarget.focus();
    };
    if (closeButton) closeButton.addEventListener("click", () => closeDialog(true));
    dialog.addEventListener("cancel", event => {
      event.preventDefault();
      closeDialog(true);
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
        const link = results.children[selected] && results.children[selected].querySelector("a");
        if (link) { event.preventDefault(); link.click(); }
      }
    });

    return {open: openDialog, render, focus: focusTarget,
      isOpen: () => dialog.open === true};
  };

  // First request builds exactly one dialog and controller; later requests reuse
  // them. A builder exception must reach the caller instead of a fake success.
  const ensureSearchDialog = () => {
    if (controller) return controller;
    const parts = buildSearchDialog();
    dialog = parts.node;
    input = parts.field;
    results = parts.list;
    closeButton = parts.close;
    searchStatus = parts.status;
    searchPages = parts.pages;
    previousPage = parts.previous;
    nextPage = parts.next;
    searchFacets = parts.facets;
    kindFilter = parts.kind;
    packageFilter = parts.pack;
    const created = createController();
    document.body.append(dialog);
    controller = created;
    // The trigger is associated with the real dialog only now that creation
    // succeeded, so a failed builder leaves no dangling aria-controls.
    if (trigger) trigger.setAttribute("aria-controls", "cjdoc-search-dialog");
    return controller;
  };
  const openSearchDialog = () => ensureSearchDialog().open();

  if (trigger) {
    trigger.hidden = false;
    // Bound once here: the first activation creates the dialog, later ones
    // reopen the same instance instead of building another.
    trigger.addEventListener("click", () => openSearchDialog());
  }
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
    if (!controller) { openSearchDialog(); return; }
    if (!controller.isOpen()) controller.open();
    else controller.focus();
  });
  window.addEventListener("popstate", () => {
    Object.assign(urlSearchState, readUrlSearchState());
    const requested = urlRequestsSearch();
    // Back/forward without search state must not build a palette just to clear
    // it; only an initialized controller keeps its results in step.
    if (!controller) { if (requested) openSearchDialog(); return; }
    if (requested && !controller.isOpen()) controller.open();
    else controller.render();
  });
  if (urlRequestsSearch()) openSearchDialog();
})();
"""

// search.js order is fixed by renderers_output.cj:
// sidebar navigation + search kernel + this dialog controller + reading
// controllers + language navigation.
internal let HTML_SEARCH_SCRIPT = HTML_SEARCH_KERNEL_SCRIPT + HTML_SEARCH_CONTROLLER_SCRIPT +
    HTML_READING_SCRIPT
