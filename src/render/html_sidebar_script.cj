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
  const currentId = sidebar ? (sidebar.dataset.cjdocCurrentSymbol || "") : "";
  const currentPage = sidebar ? (sidebar.dataset.cjdocCurrentPage || "") : "";
  const packages = [];

  const folded = value => String(value || "").toLowerCase();
  const typeRecord = typeId => data && data.types ? data.types[typeId] : null;
  const memberRecord = memberId => data && data.members ? data.members[memberId] : null;
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
  const treeLink = (href, text, kind, ancestor) => {
    const isPage = href === currentPage && href.indexOf("#") < 0;
    const link = element("a", ancestor && !isPage ? "cj-tree__link cj-tree__link--ancestor"
      : "cj-tree__link");
    if (href.indexOf("#") < 0) link.setAttribute("data-cjdoc-nav-link", "");
    if (isPage) link.setAttribute("aria-current", "page");
    link.setAttribute("href", root + href);
    if (kind) {
      const chip = element("span", "cj-tree__kind");
      chip.setAttribute("data-kind", kind);
      chip.setAttribute("aria-hidden", "true");
      link.append(chip);
    }
    const name = element("span", "cj-tree__label");
    name.textContent = text;
    link.append(name);
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
  const addToggle = (list, labelText) => {
    const button = element("button", "cj-tree__toggle");
    button.type = "button";
    button.setAttribute("data-cjdoc-tree-toggle", "");
    button.setAttribute("aria-controls", list.id);
    button.setAttribute("aria-expanded", "false");
    button.setAttribute("aria-label", (isChinese ? "展开或收起 " : "Toggle ") + labelText);
    return button;
  };
  const setExpanded = (record, expanded) => {
    if (!record.toggle || !record.list) return;
    record.toggle.setAttribute("aria-expanded", expanded ? "true" : "false");
    record.list.hidden = !expanded;
  };
  // A list built after the fact must become the toggle's target, otherwise the
  // server's aria-controls keeps naming a branch that never materializes.
  const bindToggle = (toggle, list) => {
    if (list.id) toggle.setAttribute("aria-controls", list.id);
  };

  const typeMatches = (type, query) => {
    if (!type) return false;
    if (folded(type.label).indexOf(query) >= 0) return true;
    return (type.members || []).some(memberId => {
      const member = memberRecord(memberId);
      return Boolean(member) && folded(member.label).indexOf(query) >= 0;
    });
  };
  const packageMatches = (pkg, query) => {
    if (!pkg) return false;
    if (folded(pkg.label).indexOf(query) >= 0) return true;
    return (pkg.types || []).some(typeId => typeMatches(typeRecord(typeId), query));
  };

  const memberItem = (type, memberId) => {
    const member = memberRecord(memberId);
    const item = treeItem("member", memberId);
    if (!member) return item;
    const row = element("div", "cj-tree__row");
    row.append(treeLink(type.href + "#" + member.anchor, member.label, member.kind,
      memberId === currentId));
    item.append(row);
    return item;
  };
  const fillMembers = (list, type) => {
    if (list.childElementCount) return;
    for (const memberId of type.members || []) list.append(memberItem(type, memberId));
  };
  const typeItem = typeId => {
    const type = typeRecord(typeId);
    if (!type) return null;
    const item = treeItem("type", typeId);
    const row = element("div", "cj-tree__row");
    item.append(row);
    row.append(treeLink(type.href, type.label, type.kind, typeId === currentId));
    if (!Array.isArray(type.members) || !type.members.length) return item;
    const list = addChildList(item, typeId);
    const toggle = addToggle(list, type.label);
    bindToggle(toggle, list);
    toggle.dataset.cjdocTreeBound = "true";
    row.prepend(toggle);
    toggle.addEventListener("click", () => {
      const expanded = toggle.getAttribute("aria-expanded") === "true";
      if (!expanded) fillMembers(list, type);
      setExpanded({toggle, list}, !expanded);
    });
    if (typeId === currentId) {
      fillMembers(list, type);
      setExpanded({toggle, list}, true);
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
  const ensurePackageChildren = record => record.list || buildPackageChildren(record);
  // The server renders a bounded window of a long branch; with the index loaded
  // the branch becomes complete, keeping its trailing "full index" link.
  const completePartial = (list, children) => {
    if (!list || !list.hasAttribute("data-cjdoc-tree-partial")) return;
    const more = [...list.children].filter(child =>
      child.classList.contains("cj-tree__item--more"));
    list.replaceChildren(...children.filter(Boolean), ...more);
    list.removeAttribute("data-cjdoc-tree-partial");
  };
  // Server-rendered types other than the current one carry no member list; it
  // is built from the index the first time the branch is expanded or filtered.
  const ensureTypeList = (item, type) => {
    const existing = item.querySelector(":scope > ul");
    if (existing) return existing;
    if (!type || !Array.isArray(type.members) || !type.members.length) return null;
    const list = addChildList(item, item.dataset.cjdocTreeKey);
    const toggle = item.querySelector("[data-cjdoc-tree-toggle]");
    if (toggle) bindToggle(toggle, list);
    return list;
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
      if (record.toggle) record.toggle.hidden = false;
      if (record.toggle && record.list) setExpanded(record, !record.list.hidden);
      if (record.toggle) {
        record.toggle.addEventListener("click", () => {
          const expanded = record.toggle.getAttribute("aria-expanded") === "true";
          if (!ensurePackageChildren(record)) return;
          setExpanded(record, !expanded);
        });
      }
      packages.push(record);
      if (record.pkg && Array.isArray(record.pkg.types)) {
        completePartial(record.list, record.pkg.types.map(typeItem));
      }
    }
    // Server-rendered type toggles are hidden until their listeners exist.
    for (const item of tree.querySelectorAll("[data-cjdoc-tree-item='type']")) {
      const toggle = item.querySelector("[data-cjdoc-tree-toggle]");
      if (!toggle || toggle.dataset.cjdocTreeBound) continue;
      toggle.dataset.cjdocTreeBound = "true";
      const initial = item.querySelector(":scope > ul");
      const initialType = typeRecord(item.dataset.cjdocTreeKey);
      if (initial && initialType && Array.isArray(initialType.members)) {
        completePartial(initial, initialType.members.map(id => memberItem(initialType, id)));
      }
      toggle.hidden = false;
      if (initial) setExpanded({toggle, list: initial}, !initial.hidden);
      toggle.addEventListener("click", () => {
        const type = typeRecord(item.dataset.cjdocTreeKey);
        const list = ensureTypeList(item, type);
        if (!list) return;
        const expanded = toggle.getAttribute("aria-expanded") === "true";
        if (!expanded && type) fillMembers(list, type);
        setExpanded({toggle, list}, !expanded);
      });
    }
    const filterInput = document.querySelector("[data-cjdoc-sidebar-filter]");
    if (filterInput) filterInput.addEventListener("input", filterSidebar);
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
    // Query and fragment are client state on the same document, not another page.
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
  const expandMatchingType = (elementNode, type, query) => {
    const list = ensureTypeList(elementNode, type);
    const toggle = elementNode.querySelector("[data-cjdoc-tree-toggle]");
    if (!list || !toggle) return;
    const nameHit = folded(type.label).indexOf(query) >= 0;
    if (!nameHit) fillMembers(list, type);
    for (const member of list.children) {
      const label = member.querySelector(".cj-tree__label");
      const matches = nameHit || folded(label ? label.textContent : "").indexOf(query) >= 0;
      member.hidden = !matches;
    }
    setExpanded({toggle, list}, true);
  };

  const applyFilter = query => {
    let total = 0;
    const modules = new Map();
    for (const record of packages) {
      const pkg = record.pkg || packageData(record.id);
      record.pkg = pkg;
      const packageHit = Boolean(pkg) && folded(pkg.label).indexOf(query) >= 0;
      const matching = !packageHit && !packageMatches(pkg, query);
      record.item.hidden = matching;
      if (matching) continue;
      total += 1;
      const module = record.module || record.item;
      modules.set(module, (modules.get(module) || 0) + 1);
      if (!ensurePackageChildren(record)) continue;
      setExpanded(record, true);
      for (const typeElement of typeElements(record)) {
        const type = typeRecord(typeElement.dataset.cjdocTreeKey);
        const hit = packageHit || typeMatches(type, query);
        typeElement.hidden = !hit;
        if (hit && type && type.members && type.members.length) {
          expandMatchingType(typeElement, type, query);
        }
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

  const restoreTree = () => {
    for (const record of packages) {
      record.item.hidden = false;
      const module = record.module || record.item;
      module.hidden = false;
      if (record.list) {
        for (const child of record.list.children) {
          child.hidden = false;
          const members = child.querySelector(":scope > ul");
          const toggle = child.querySelector("[data-cjdoc-tree-toggle]");
          if (!members || !toggle) continue;
          for (const member of members.children) member.hidden = false;
          setExpanded({toggle, list: members}, Boolean(child.querySelector(
            ".cj-tree__link--ancestor, .cj-tree__link[aria-current='page']")));
        }
        setExpanded(record, Boolean(record.item.querySelector(
          ".cj-tree__link--ancestor, .cj-tree__link[aria-current='page']")));
      }
    }
  };

  const filterSidebar = () => {
    const input = document.querySelector("[data-cjdoc-sidebar-filter]");
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
        .filter(node => !node.hidden && !node.disabled && node.tabIndex >= 0);
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
  initDrawer();
  syncRouteState();
  window.addEventListener("hashchange", syncRouteState);
  window.addEventListener("popstate", syncRouteState);
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(positionSidebar);
})();
"""
