package cjdoc.render

// Lazy sidebar tree, package filter, drawer and route state. Everything here is
// an enhancement: the server-rendered tree already shows the current package
// branch, so a reader without scripts keeps working navigation.
//
// The filter decides visibility from the shared index data alone, so matching a
// member never forces the whole tree to be materialized in the DOM.
internal let HTML_SIDEBAR_SCRIPT = """
(() => {
  const sidebar = document.querySelector("#cjdoc-sidebar");
  const tree = document.querySelector("[data-cjdoc-sidebar-tree]");
  const data = globalThis.__CJDOC_SIDEBAR_INDEX__ || null;
  const isChinese = (document.documentElement.lang || "").toLowerCase().startsWith("zh");
  const root = sidebar ? (sidebar.dataset.cjdocRootPrefix || "") : "";
  const apiRoot = sidebar ? (sidebar.dataset.cjdocApiPrefix ?? root) : root;
  const currentId = sidebar ? (sidebar.dataset.cjdocCurrentSymbol || "") : "";
  const currentPage = sidebar ? (sidebar.dataset.cjdocCurrentPage || "") : "";
  const packages = [];

  const folded = value => String(value || "").toLowerCase();
  const ownRecord = (table, id) => table && Object.hasOwn(table, id) ? table[id] : null;
  const typeRecord = typeId => ownRecord(data?.types, typeId);
  const memberRecord = memberId => ownRecord(data?.members, memberId);
  const packageData = id => {
    if (!data || !Array.isArray(data.packages)) return null;
    return data.packages.find(pkg => pkg.id === id) || null;
  };
  const element = (tag, className) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    return node;
  };
  const treeItem = (kind, key) => {
    const item = element("li", "cj-tree__item");
    item.setAttribute("data-cjdoc-tree-item", kind);
    item.setAttribute("data-cjdoc-tree-key", key);
    return item;
  };
  const treeLink = (href, text, kind, ancestor, id) => {
    const isPage = href === currentPage && href.indexOf("#") < 0;
    const link = element("a", ancestor && !isPage ? "cj-tree__link cj-tree__link--ancestor"
      : "cj-tree__link");
    if (href.indexOf("#") < 0) link.setAttribute("data-cjdoc-nav-link", "");
    if (isPage) link.setAttribute("aria-current", "page");
    link.setAttribute("href", href.startsWith("#") ? href :
      kind ? globalThis.__CJDOC_API_ROUTE__(apiRoot + href) : root + href);
    if (kind) {
      const chip = element("span", "cj-tree__kind");
      chip.setAttribute("data-kind", kind);
      chip.setAttribute("aria-hidden", "true");
      link.append(chip);
    }
    const name = element("span", "cj-tree__label");
    name.textContent = text;
    link.append(name);
    if (globalThis.__CJDOC_DEPRECATION__(id) !== undefined) {
      const status = element("span", "cj-deprecation");
      status.textContent = isChinese ? "已弃用" : "Deprecated";
      link.append(status);
    }
    return link;
  };
  const addChildList = (owner, id) => {
    const list = element("ul", "cj-tree__children");
    list.id = "cjdoc-tree-js-" + id;
    list.setAttribute("data-cjdoc-tree-children", "");
    list.hidden = true;
    owner.append(list);
    return list;
  };
  const addToggle = labelText => {
    const button = element("button", "cj-tree__toggle");
    button.type = "button";
    button.setAttribute("data-cjdoc-tree-toggle", "");
    button.setAttribute("aria-expanded", "false");
    button.setAttribute("aria-label", (isChinese ? "展开或收起 " : "Toggle ") + labelText);
    return button;
  };
  const setExpanded = (record, expanded) => {
    if (!record.toggle || !record.list) return;
    record.toggle.setAttribute("aria-expanded", expanded ? "true" : "false");
    record.list.hidden = !expanded;
  };
  // A lazy list must become the toggle's real aria-controls target.
  const bindToggle = (toggle, list) => {
    if (list.id) toggle.setAttribute("aria-controls", list.id);
  };

  const memberMatches = (ownerId, memberId, query, matches) => {
    const member = memberRecord(memberId);
    return Boolean(member) && (folded(member.label).includes(query) ||
      (member.ownerId === ownerId && typeMatches(memberId, query, matches)));
  };
  const typeMatches = (typeId, query, matches) => {
    if (matches.has(typeId)) return matches.get(typeId);
    const type = typeRecord(typeId);
    const hit = Boolean(type) && (folded(type.label).includes(query) ||
      (type.members || []).some(id => memberMatches(typeId, id, query, matches)));
    matches.set(typeId, hit);
    return hit;
  };
  const itemToggle = item => item.querySelector(":scope > .cj-tree__row > [data-cjdoc-tree-toggle]");

  const memberItem = (ownerId, type, memberId) => {
    const member = memberRecord(memberId);
    if (!member) return null;
    const item = treeItem("member", memberId);
    const row = element("div", "cj-tree__row");
    const href = (type.href === currentPage ? "" : type.href) + "#" + member.anchor;
    row.append(treeLink(href, member.label, member.kind, false, memberId));
    item.append(row);
    // Inherited or extension context is a real anchor on this owner, not a
    // second owner edge from which to recurse.
    if (member.ownerId === ownerId && typeRecord(memberId)?.members.length) {
      const toggle = addToggle(member.label);
      row.prepend(toggle);
      bindTypeToggle(item, toggle);
    }
    return item;
  };
  const fillMembers = (list, type, ownerId) => {
    const create = id => memberItem(ownerId, type, id);
    if (list.hasAttribute("data-cjdoc-tree-partial")) return completePartial(list, type.members, create);
    if (list.childElementCount) return null;
    for (const memberId of type.members) {
      const child = create(memberId);
      if (child) list.append(child);
    }
    return null;
  };
  const typeItem = typeId => {
    const type = typeRecord(typeId);
    if (!type) return null;
    const item = treeItem("type", typeId);
    const row = element("div", "cj-tree__row");
    item.append(row);
    row.append(treeLink(type.href, type.label, type.kind, typeId === currentId, typeId));
    if (type.members?.length) {
      const toggle = addToggle(type.label);
      row.prepend(toggle);
      bindTypeToggle(item, toggle);
    }
    return item;
  };
  const buildPackageChildren = record => {
    const pkg = packageData(record.id);
    if (!pkg || !Array.isArray(pkg.types)) return null;
    record.list = addChildList(record.item, record.id);
    if (record.toggle) bindToggle(record.toggle, record.list);
    for (const typeId of pkg.types) {
      const child = typeItem(typeId);
      if (child) record.list.append(child);
    }
    return record.list;
  };
  // Keep the server window until explicit expansion or filtering needs all children.
  const ensurePackageChildren = record => {
    if (!record.list) return buildPackageChildren(record);
    if (record.list.hasAttribute("data-cjdoc-tree-partial") && record.pkg &&
      Array.isArray(record.pkg.types)) {
      completePartial(record.list, record.pkg.types, typeItem);
    }
    return record.list;
  };
  // Keep work already expanded inside the window, and insert the other
  // immediate children in publisher order. No grandchildren are built here.
  const completePartial = (list, ids, create) => {
    if (!list || !list.hasAttribute("data-cjdoc-tree-partial")) return null;
    const existing = new Map();
    const more = [];
    for (const child of list.children) {
      if (child.classList.contains("cj-tree__item--more")) more.push(child);
      else existing.set(child.dataset.cjdocTreeKey, child);
    }
    let firstNew = null;
    const children = [];
    for (const id of ids) {
      const old = existing.get(id);
      const child = old || create(id);
      if (!child) continue;
      children.push(child);
      if (!old && !firstNew) firstNew = child;
    }
    list.replaceChildren(...children, ...more);
    list.removeAttribute("data-cjdoc-tree-partial");
    for (const item of more) {
      const button = item.querySelector("[data-cjdoc-sidebar-reveal]");
      const link = item.querySelector("[data-cjdoc-sidebar-more]");
      if (button) button.hidden = true;
      if (link) link.hidden = false;
    }
    return firstNew;
  };
  const bindReveal = (list, fill, choice) => {
    if (!list || !list.hasAttribute("data-cjdoc-tree-partial")) return;
    const button = list.querySelector(":scope > .cj-tree__item--more > [data-cjdoc-sidebar-reveal]");
    if (!button) return;
    const link = button.parentElement.querySelector("[data-cjdoc-sidebar-more]");
    button.hidden = false;
    if (link) link.hidden = true;
    button.addEventListener("click", () => {
      fill()?.querySelector("a")?.focus();
      choice();
    });
  };
  // Other types build their member list only when expanded or filtered.
  const ensureTypeList = (item, type) => {
    const existing = item.querySelector(":scope > ul");
    if (existing) return existing;
    if (!type || !Array.isArray(type.members) || !type.members.length) return null;
    const list = addChildList(item, item.dataset.cjdocTreeKey);
    const toggle = itemToggle(item);
    if (toggle) bindToggle(toggle, list);
    return list;
  };
  const bindTypeToggle = (item, toggle) => {
    const id = item.dataset.cjdocTreeKey;
    const type = typeRecord(id);
    if (!type || !type.members.length) return;
    const initial = item.querySelector(":scope > ul");
    toggle.hidden = false;
    toggle.dataset.cjdocTreeExpanded = toggle.getAttribute("aria-expanded");
    if (initial) setExpanded({toggle, list: initial}, !initial.hidden);
    bindReveal(initial, () => fillMembers(initial, type, id), () => rememberBranch(item, true));
    toggle.addEventListener("click", () => {
      const list = ensureTypeList(item, type);
      if (!list) return;
      const expanded = toggle.getAttribute("aria-expanded") === "true";
      if (!expanded) fillMembers(list, type, id);
      setExpanded({toggle, list}, !expanded);
      rememberBranch(item, !expanded);
    });
  };

  const initSidebarTree = () => {
    if (!tree || !data) return;
    for (const item of tree.querySelectorAll("[data-cjdoc-tree-item='package']")) {
      const record = {
        item,
        id: item.dataset.cjdocTreeKey,
        module: item.closest("[data-cjdoc-tree-module]"),
        list: item.querySelector(":scope > ul"),
        toggle: item.querySelector("[data-cjdoc-tree-toggle]"),
        pkg: packageData(item.dataset.cjdocTreeKey)
      };
      if (record.toggle && record.list) setExpanded(record, !record.list.hidden);
      if (record.toggle && record.pkg?.types.length) {
        record.toggle.hidden = false;
        record.toggle.dataset.cjdocTreeExpanded = record.toggle.getAttribute("aria-expanded");
        bindReveal(record.list, () => completePartial(record.list, record.pkg.types, typeItem),
          () => rememberBranch(item, true));
        record.toggle.addEventListener("click", () => {
          const expanded = record.toggle.getAttribute("aria-expanded") === "true";
          if (!expanded && !ensurePackageChildren(record)) return;
          setExpanded(record, !expanded);
          rememberBranch(item, !expanded);
        });
      }
      packages.push(record);
    }
    // Expose toggles only after binding their listeners.
    for (const item of tree.querySelectorAll("[data-cjdoc-tree-item='type'],[data-cjdoc-tree-item='member']")) {
      const toggle = itemToggle(item);
      if (toggle) bindTypeToggle(item, toggle);
    }
    const filterInput = document.querySelector("[data-cjdoc-sidebar-filter]");
    if (filterInput) {
      filterInput.addEventListener("input", () => {
        filterSidebar();
        saveFilter();
      });
    }
  };

  const syncRouteState = () => {
    if (!sidebar) return;
    const declaredRoute = document.body.dataset.cjdocRoute || "overview";
    const hash = window.location.hash || "";
    const links = [...sidebar.querySelectorAll(".cj-sidebar__link")];
    const href = link => link.getAttribute("href") || "";
    const overview = links.find(link =>
      href(link).indexOf("index.html") >= 0 && href(link).indexOf("#") < 0);
    const api = links.find(link => href(link).indexOf("#packages") >= 0);
    // Query and hash are state on this document, not another page.
    const onOverview = sidebar.dataset.cjdocCurrentPage === "index.html";
    const onApi = declaredRoute === "api" ||
      (declaredRoute === "overview" && hash === "#packages");
    for (const [link, active] of [[overview, onOverview], [api, onApi]]) {
      if (!link) continue;
      const page = link === overview && onOverview;
      link.classList.toggle("cj-sidebar__link--ancestor", !page && active);
      if (page) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    }
  };

  const positionSidebar = () => {
    if (!sidebar) return;
    const ancestors = sidebar.querySelectorAll(".cj-tree__link--ancestor");
    const selected = sidebar.querySelector(".cj-tree__link[aria-current='page']") ||
      ancestors[ancestors.length - 1] ||
      sidebar.querySelector(".cj-sidebar__link[aria-current='page']");
    if (!selected) return;
    sidebar.scrollTop = Math.max(0, sidebar.scrollTop + selected.getBoundingClientRect().top -
      sidebar.getBoundingClientRect().top - sidebar.clientHeight / 3);
  };

  const typeElements = record => {
    if (!record.list) return [];
    return [...record.list.children].filter(child =>
      child.dataset.cjdocTreeItem === "type");
  };
  const expandMatchingType = (item, id, type, query, matches) => {
    const list = ensureTypeList(item, type);
    const toggle = itemToggle(item);
    if (!list || !toggle) return;
    const nameHit = folded(type.label).includes(query);
    fillMembers(list, type, id);
    for (const member of list.children) {
      if (member.classList.contains("cj-tree__item--more")) { member.hidden = false; continue; }
      const memberId = member.dataset.cjdocTreeKey;
      const hit = memberMatches(id, memberId, query, matches);
      member.hidden = !nameHit && !hit;
      if (hit && memberRecord(memberId)?.ownerId === id) {
        const nested = typeRecord(memberId);
        if (nested?.members.length) expandMatchingType(member, memberId, nested, query, matches);
      }
    }
    setExpanded({toggle, list}, true);
  };

  const applyFilter = query => {
    let total = 0;
    const modules = new Map();
    const matches = new Map();
    for (const record of packages) {
      const pkg = record.pkg || packageData(record.id);
      record.pkg = pkg;
      const packageHit = Boolean(pkg) && folded(pkg.label).indexOf(query) >= 0;
      const hidden = !packageHit && !(pkg?.types || []).some(id => typeMatches(id, query, matches));
      record.item.hidden = hidden;
      if (hidden) continue;
      total += 1;
      const module = record.module || record.item;
      modules.set(module, (modules.get(module) || 0) + 1);
      if (!ensurePackageChildren(record)) continue;
      setExpanded(record, true);
      for (const typeElement of typeElements(record)) {
        const id = typeElement.dataset.cjdocTreeKey;
        const type = typeRecord(id);
        const hit = typeMatches(id, query, matches);
        typeElement.hidden = !packageHit && !hit;
        if (hit && type?.members.length) expandMatchingType(typeElement, id, type, query, matches);
      }
    }
    for (const record of packages) {
      const module = record.module || record.item;
      if (!modules.has(module)) {
        module.hidden = true;
      }
    }
    for (const [module, count] of modules) module.hidden = count === 0;
    return total;
  };

  const restoreVisibleChildren = list => {
    if (!list) return;
    for (const child of list.children) {
      child.hidden = false;
      const nested = child.querySelector(":scope > ul");
      const toggle = itemToggle(child);
      if (!nested || !toggle) continue;
      restoreVisibleChildren(nested);
      setExpanded({toggle, list: nested}, toggle.dataset.cjdocTreeExpanded === "true");
    }
  };
  const restoreTree = () => {
    for (const record of packages) {
      record.item.hidden = false;
      (record.module || record.item).hidden = false;
      restoreVisibleChildren(record.list);
      setExpanded(record, record.toggle?.dataset.cjdocTreeExpanded === "true");
    }
  };

  const filterControl = () => document.querySelector("[data-cjdoc-sidebar-filter]");
  const filterSidebar = () => {
    const input = filterControl();
    if (!input || !tree) return;
    const empty = document.querySelector("[data-cjdoc-sidebar-no-results]");
    const query = folded(input.value.trim());
    if (!query) {
      restoreTree();
      if (empty) empty.hidden = true;
      return;
    }
    const total = applyFilter(query);
    if (empty) empty.hidden = total > 0;
  };

  // Cache the narrowed tree per document, restoring only on Back/Forward.
  const pageKey = name => name + ":" + [document.body.dataset.cjdocDocVersion || "",
    document.documentElement.lang, window.location.pathname].join("|");
  // Fresh navigations start clean.
  const historyReturn = () => {
    const entry = typeof performance !== "undefined" &&
      performance.getEntriesByType ? performance.getEntriesByType("navigation")[0] : null;
    return Boolean(entry) && entry.type === "back_forward";
  };
  const filterKey = () => pageKey("cjdoc-sidebar-filter");
  const saveFilter = () => {
    const input = filterControl();
    if (!input) return;
    try { sessionStorage.setItem(filterKey(), input.value); } catch (_) { /* optional */ }
  };
  const restoreFilter = () => {
    const input = filterControl();
    if (!input) return;
    if (!historyReturn()) return;
    let saved = "";
    try { saved = sessionStorage.getItem(filterKey()) || ""; } catch (_) { saved = ""; }
    if (!saved) return;
    input.value = saved;
    filterSidebar();
  };

  // Browser back-forward caches keep the live DOM when available. Restore the
  // same explicit branch choices if the browser rebuilt the document instead.
  const branchChoices = new Map();
  const branchKey = () => pageKey("cjdoc-sidebar-branches");
  const rememberBranch = (item, expanded) => {
    const toggle = itemToggle(item);
    if (toggle) toggle.dataset.cjdocTreeExpanded = expanded ? "true" : "false";
    if (!toggle) return;
    branchChoices.set(item.dataset.cjdocTreeKey, expanded);
    // A deliberate choice inside a filtered branch also makes its open
    // ancestors reachable when the filter is cleared and after history return.
    let parent = item.parentElement?.closest("[data-cjdoc-tree-item]");
    while (parent && tree.contains(parent)) {
      const parentToggle = itemToggle(parent);
      if (parentToggle?.getAttribute("aria-expanded") === "true") {
        parentToggle.dataset.cjdocTreeExpanded = "true";
        branchChoices.set(parent.dataset.cjdocTreeKey, true);
      }
      parent = parent.parentElement?.closest("[data-cjdoc-tree-item]");
    }
    try { sessionStorage.setItem(branchKey(), JSON.stringify([...branchChoices])); } catch (_) { /* optional */ }
  };
  const restoreBranches = () => {
    if (!tree || !historyReturn()) return;
    let saved;
    try { saved = JSON.parse(sessionStorage.getItem(branchKey()) || "[]"); } catch (_) { return; }
    if (!Array.isArray(saved)) return;
    const restore = (item, expanded) => {
      const toggle = itemToggle(item);
      if (!toggle) return;
      toggle.dataset.cjdocTreeExpanded = expanded ? "true" : "false";
      const record = packages.find(pkg => pkg.item === item);
      if (record) {
        ensurePackageChildren(record);
        setExpanded(record, expanded);
      } else {
        const id = item.dataset.cjdocTreeKey;
        const type = typeRecord(id);
        const list = ensureTypeList(item, type);
        if (list) fillMembers(list, type, id);
        setExpanded({toggle, list}, expanded);
      }
    };
    const remaining = new Map(saved.filter(row => Array.isArray(row) &&
      typeof row[0] === "string" && typeof row[1] === "boolean"));
    const visit = item => {
      const id = item.dataset.cjdocTreeKey;
      if (remaining.has(id)) {
        const expanded = remaining.get(id);
        restore(item, expanded);
        branchChoices.set(id, expanded);
      }
      const list = item.querySelector(":scope > ul");
      if (list) for (const child of list.children) visit(child);
    };
    for (const record of packages) visit(record.item);
  };
  // Native history restores document scroll, not nested sidebar scroll.
  // Capture at pagehide to beat queued events; restore only on Back/Forward.
  let sidebarOffset = 0;
  const scrollKey = () => pageKey("cjdoc-sidebar-scroll");
  const scrollPanel = () => document.querySelector("#cjdoc-sidebar");
  const initScroll = () => {
    const panel = scrollPanel();
    if (!panel) return;
    panel.addEventListener("scroll", () => { sidebarOffset = panel.scrollTop; }, {passive: true});
  };
  const saveScroll = () => {
    const panel = scrollPanel();
    try { sessionStorage.setItem(scrollKey(), String(panel ? panel.scrollTop : 0)); }
    catch (_) { /* optional */ }
  };
  const restoreScroll = () => {
    const panel = scrollPanel();
    if (!panel) return;
    if (!historyReturn()) return;
    let saved = NaN;
    try { saved = Number(sessionStorage.getItem(scrollKey())); } catch (_) { saved = NaN; }
    if (!Number.isFinite(saved) || saved < 0) return;
    sidebarOffset = saved;
    panel.scrollTop = saved;
  };

  const initDrawer = () => {
    const menu = document.querySelector("[data-cjdoc-menu]");
    const backdrop = document.querySelector("[data-cjdoc-menu-backdrop]");
    const closeButton = document.querySelector("[data-cjdoc-sidebar-close]");
    if (!menu || !sidebar) return;
    const surfaces = () => [...document.querySelectorAll(".cj-header, .cj-main, " +
      ".cj-toc, .cj-footer")];
    const apply = drawerOpen => {
      menu.setAttribute("aria-expanded", drawerOpen ? "true" : "false");
      menu.setAttribute("aria-label", drawerOpen
        ? (isChinese ? "关闭导航" : "Close navigation")
        : (isChinese ? "打开导航" : "Open navigation"));
      if (drawerOpen) document.documentElement.setAttribute("data-cj-drawer", "open");
      else document.documentElement.removeAttribute("data-cj-drawer");
      if (backdrop) backdrop.hidden = !drawerOpen;
      for (const surface of surfaces()) {
        if (drawerOpen) surface.setAttribute("inert", "");
        else surface.removeAttribute("inert");
      }
      if (drawerOpen) {
        sidebar.setAttribute("role", "dialog");
        sidebar.setAttribute("aria-modal", "true");
        const target = sidebar.querySelector("[data-cjdoc-sidebar-filter], " +
          "[data-cjdoc-sidebar-close], a[href]");
        if (target && typeof target.focus === "function") target.focus();
        else if (typeof sidebar.focus === "function") sidebar.focus();
      } else {
        sidebar.removeAttribute("role");
        sidebar.removeAttribute("aria-modal");
      }
    };
    const close = (restoreFocus = false) => {
      if (menu.getAttribute("aria-expanded") !== "true") return;
      apply(false);
      if (restoreFocus && typeof menu.focus === "function") menu.focus();
    };
    menu.addEventListener("click", () => {
      if (menu.getAttribute("aria-expanded") === "true") close(true);
      else apply(true);
    });
    if (closeButton) closeButton.addEventListener("click", () => close(true));
    if (backdrop) backdrop.addEventListener("click", () => close(true));
    sidebar.addEventListener("click", event => {
      if (event.target.closest && event.target.closest("a[href]")) close(false);
    });
    document.addEventListener("keydown", event => {
      if (menu.getAttribute("aria-expanded") !== "true") return;
      if (event.key === "Escape") { event.preventDefault(); close(true); return; }
      if (event.key !== "Tab") return;
      const focusable = [...sidebar.querySelectorAll("a[href], button, input, [tabindex]")]
        .filter(node => node.getClientRects().length && !node.disabled && node.tabIndex >= 0);
      if (!focusable.length) { event.preventDefault(); return; }
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    });
    window.addEventListener("resize", () => {
      if (!window.matchMedia || !window.matchMedia("(max-width: 760px)").matches) close(false);
    });
  };

  initSidebarTree();
  initScroll();
  restoreBranches();
  restoreFilter();
  restoreScroll();
  initDrawer();
  syncRouteState();
  window.addEventListener("hashchange", syncRouteState);
  window.addEventListener("popstate", syncRouteState);
  window.addEventListener("pagehide", () => {
    saveFilter();
    saveScroll();
  });
  // Deferred scripts settle tree size; history restoration takes priority.
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(() => {
    if (sidebarOffset > 0) return;
    positionSidebar();
  });
})();
"""
