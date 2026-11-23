protected package cjdoc.render.browser

// The trigger carries the publication prefix before the lazy search dialog is built.
// One controller binds listeners per dialog. URL tag changes preserve other query tokens;
// incoming tag or snapshot links open the dialog rather than hiding the requested results.
internal let HTML_SEARCH_CONTROLLER_SETUP_SCRIPT = """
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
    const replacement = createElement("div", "cj-search__replacement");
    replacement.hidden = true;
    node.append(replacement);
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
    return {node, field, close, list, status, pages, previous, next, facets, kind, pack, replacement};
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
  let searchReplacement = null;
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

"""
