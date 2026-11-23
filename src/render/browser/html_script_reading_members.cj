protected package cjdoc.render.browser

// Member filtering and history, followed by initialization in browser order.
internal let HTML_READING_MEMBERS_SCRIPT = """
  const initMembers = () => {
    const browser = find("[data-cjdoc-member-browser]");
    if (!browser) return;
    const kernel = globalThis.cjdocSearch;
    const index = globalThis.__CJDOC_SEARCH_INDEX__;
    const rows = [...all("[data-cjdoc-member]")];
    const memberFilter = kernel?.createEntryFilter(index, rows.map(row => row.dataset.memberSymbolId));
    let unfiltered;
    const memberGroups = selector => Array.from(all(selector), group =>
      [group, [...group.querySelectorAll("[data-cjdoc-member]")]]);
    const groups = memberGroups("[data-cjdoc-member-group]");
    const overloads = memberGroups("[data-cjdoc-overload-group]");
    const roles = memberGroups("[data-cjdoc-declaration-group]");
    const visibleCount = members => members.reduce((count, row) => count + Number(!row.hidden), 0);
    const filter = find("[data-cjdoc-member-filter]");
    const origin = find("[data-cjdoc-member-origin]");
    const filterToggle = find("[data-cjdoc-member-filter-toggle]");
    const filterFields = find("#cjdoc-member-filter-fields");
    const status = find("[data-cjdoc-member-filter-status]");
    const expand = find("[data-cjdoc-members-expand]");
    const collapse = find("[data-cjdoc-members-collapse]");
    let notice = "";
    const syncActions = () => {
      if (expand) expand.disabled = !rows.some(row => !row.hidden && !row.open);
      if (collapse) collapse.disabled = !rows.some(row => !row.hidden && row.open);
    };
    let openAction;
    const closeActionMenus = restoreFocus => {
      if (!openAction) return;
      const toggle = openAction;
      openAction = null;
      toggle.setAttribute("aria-expanded", "false");
      if (restoreFocus) toggle.focus();
    };
    const emptyIds = new Set();
    const applyFilter = () => {
      closeActionMenus();
      const raw = filter ? filter.value : "";
      const selectedOrigin = origin ? origin.value : "";
      const parsed = kernel && index
        ? kernel.parseQuery(raw, index.contract)
        : {errorCode: "search_index_unavailable", query: "", filters: [], tags: []};
      let error = parsed.errorCode || null;
      const active = Boolean(parsed.query || parsed.filters.length || parsed.tags.length);
      let matching = emptyIds;
      if (!error) {
        if (!active && unfiltered) {
          ({error, matching} = unfiltered);
        } else {
          const request = {query: parsed.query, filters: parsed.filters};
          if (parsed.tags.length) request.tags = parsed.tags;
          const result = memberFilter(request);
          if (result.status !== "ok") error = result.errorCode || "search_index_invalid";
          else matching = new Set(result.canonicalIds);
          if (!active) unfiltered = {error, matching};
        }
      }
      if (filterToggle && filterFields) {
        const count = Number(active) + Number(Boolean(selectedOrigin));
        filterToggle.textContent = text("Filter members", "筛选成员") +
          (count ? " (" + count + ")" : "");
      }
      let visible = 0;
      for (const row of rows) {
        const queryMatches = !error && matching.has(row.dataset.memberSymbolId);
        const originMatches = !selectedOrigin || row.dataset.memberOrigin === selectedOrigin;
        const matches = queryMatches && originMatches;
        const hidden = !matches;
        if (row.hidden !== hidden) row.hidden = hidden;
        const wrapper = row.closest(".cj-member-row");
        if (wrapper && wrapper.hidden !== hidden) wrapper.hidden = hidden;
        if (matches) visible += 1;
      }
      browser.toggleAttribute("data-cjdoc-member-filtered", visible !== rows.length);
      for (const [group, members] of overloads) {
        const total = Number(group.dataset.overloadTotal);
        const matches = visibleCount(members);
        group.hidden = matches === 0;
        const count = group.querySelector("[data-cjdoc-overload-count]");
        if (count && Number.isFinite(total) && total > 0) {
          count.textContent = matches === total
            ? (isChinese ? total + " 个重载" : total + " overloads")
            : (isChinese ? matches + " / " + total + " 个重载"
              : matches + " of " + total + " overloads");
        }
      }
      for (const [group, members] of groups) {
        const matches = visibleCount(members);
        group.hidden = matches === 0;
        const count = group.querySelector(".cj-member-group__count");
        if (count) {
          const value = matches === members.length ? String(members.length)
            : matches + " / " + members.length;
          count.textContent = isChinese ? value + " 个成员"
            : value + (members.length === 1 ? " member" : " members");
        }
      }
      for (const [role, members] of roles) {
        const matches = visibleCount(members);
        role.hidden = members.length > 0 && matches === 0;
        const count = role.querySelector("[data-cjdoc-group-count]");
        if (count) {
          const total = Number(count.dataset.groupTotal);
          const value = matches === total ? String(total) : matches + " / " + total;
          count.textContent = isChinese ? "（" + value + "）" : " (" + value + ")";
        }
      }
      syncActions();
      syncTocVisibility();
      if (!status) return;
      if (error) {
        status.textContent = text("Member filter error: ", "成员筛选错误：") + error;
        status.hidden = false;
        return;
      }
      const activeState = Boolean(active || selectedOrigin || notice);
      status.hidden = !activeState;
      if (!activeState) return;
      const countText = isChinese ? "匹配成员：" + visible
        : visible + " matching member" + (visible === 1 ? "" : "s");
      status.textContent = countText + notice;
    };
    if (filterToggle && filterFields) {
      filterToggle.addEventListener("click", () => {
        const opening = filterToggle.getAttribute("aria-expanded") !== "true";
        filterToggle.setAttribute("aria-expanded", opening ? "true" : "false");
        if (opening) filterFields.setAttribute("data-cj-open", "");
        else filterFields.removeAttribute("data-cj-open");
        if (opening && filter) filter.focus();
      });
      filterToggle.hidden = false;
    }
    if (filter) filter.addEventListener("input", () => { notice = ""; applyFilter(); });
    if (origin) origin.addEventListener("change", () => { notice = ""; applyFilter(); });
    for (const button of [expand, collapse]) {
      if (!button) continue;
      const target = button === expand;
      button.addEventListener("click", () => {
        for (const row of rows) if (!row.hidden) row.open = target;
        syncActions();
      });
    }
    browser.addEventListener("click", event => {
      const toggle = event.target.closest?.("[data-cjdoc-member-actions-toggle]");
      if (!toggle) return;
      const opening = toggle !== openAction;
      closeActionMenus();
      if (opening) {
        openAction = toggle;
        toggle.setAttribute("aria-expanded", "true");
      }
    });
    browser.addEventListener("keydown", event => {
      if (event.key !== "Escape" || !openAction) return;
      const menu = openAction.closest("[data-cjdoc-member-actions]");
      if (!menu.contains(event.target)) return;
      event.preventDefault();
      closeActionMenus(true);
    });
    browser.addEventListener("focusout", event => {
      const menu = openAction?.closest("[data-cjdoc-member-actions]");
      if (menu?.contains(event.target) && !menu.contains(event.relatedTarget)) closeActionMenus();
    });
    document.addEventListener("pointerdown", event => {
      if (!event.target.closest || !event.target.closest("[data-cjdoc-member-actions]")) {
        closeActionMenus();
      }
    });
    const revealHashTarget = (scroll = false) => {
      if (!window.location.hash || window.location.hash.length <= 1) return;
      let id = window.location.hash.slice(1);
      try { id = decodeURIComponent(id); } catch (_) { /* keep raw */ }
      const target = document.getElementById(id);
      if (!target) return;
      const member = target.matches("[data-cjdoc-member]") ? target
        : target.closest("[data-cjdoc-member]");
      if (!member || member.tagName !== "DETAILS") return;
      if (member.hidden) {
        if (filter) filter.value = "";
        if (origin) origin.value = "";
        notice = text(". Filters cleared to reveal the linked member.",
          "；已清除筛选以显示链接目标。");
        applyFilter();
      }
      member.hidden = false;
      member.open = true;
      const group = member.closest("[data-cjdoc-member-group]");
      if (group) group.hidden = false;
      syncActions();
      if (scroll) requestAnimationFrame(() => member.scrollIntoView({block: "start"}));
    };
    const stateKey = "cjdoc-member-state:" + [document.body.dataset.cjdocProject || "",
      document.body.dataset.cjdocDocVersion || "", document.documentElement.lang,
      document.body.dataset.cjdocAudience || "", location.pathname].join("|");
    const saveState = () => {
      try {
        sessionStorage.setItem(stateKey, JSON.stringify({
          open: rows.filter(row => row.open).map(row => row.id).filter(Boolean),
          filter: filter ? filter.value : "",
          origin: origin ? origin.value : "",
        }));
      } catch (_) { /* storage is optional */ }
    };
    const navigationEntry = typeof performance !== "undefined" &&
      performance.getEntriesByType ? performance.getEntriesByType("navigation")[0] : null;
    const isHistoryNavigation = Boolean(navigationEntry && navigationEntry.type === "back_forward");
    const restoreState = () => {
      let stored = null;
      try { stored = JSON.parse(sessionStorage.getItem(stateKey) || "null"); }
      catch (_) { stored = null; }
      if (!stored || typeof stored !== "object") return false;
      if (window.location.hash && window.location.hash.length > 1 && !isHistoryNavigation) return false;
      if (filter && typeof stored.filter === "string") filter.value = stored.filter;
      if (origin && typeof stored.origin === "string" &&
          [...origin.options].some(option => option.value === stored.origin)) {
        origin.value = stored.origin;
      }
      applyFilter();
      if (Array.isArray(stored.open)) {
        for (const row of rows) row.open = stored.open.includes(row.id);
      }
      syncActions();
      return true;
    };
    const restored = restoreState();
    for (const row of rows) row.addEventListener("toggle", () => {
      syncActions();
      saveState();
    });
    for (const button of [expand, collapse]) {
      if (!button) continue;
      button.addEventListener("click", saveState);
    }
    if (filter) filter.addEventListener("input", saveState);
    if (origin) origin.addEventListener("change", saveState);
    window.addEventListener("pagehide", saveState);
    if (!restored) applyFilter();
    if (!restored) revealHashTarget(true);
    window.addEventListener("hashchange", () => revealHashTarget(true));
    document.addEventListener("click", event => {
      if (event.defaultPrevented || event.button || event.ctrlKey || event.metaKey ||
          event.shiftKey || event.altKey) return;
      const link = event.target && event.target.closest ? event.target.closest("a[href*='#']") : null;
      if (!link) return;
      let target;
      try { target = new URL(link.href, window.location.href); } catch (_) { return; }
      if (target.href !== window.location.href) return;
      requestAnimationFrame(() => revealHashTarget(true));
    });
  };

  initSettings();
  initToc();
  initCopy();
  initMembers();
})();
"""
