protected package cjdoc.render.browser

internal let HTML_SEARCH_CONTROLLER_INTERACTION_SCRIPT = """
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

    const render = () => {
      resetSearch();
      if (!kernel || !index) { showError("search_index_unavailable"); return; }
      if (urlSearchState.errorCode) {
        showError(urlSearchState.errorCode, urlSearchState.invalidToken);
        return;
      }
      if (indexCapabilityError) { showError(indexCapabilityError); return; }
      refreshFieldControls();
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
      if (!parsed.query && !filters.length && !tags.length && !urlSearchState.hasScope &&
          !appliedCommentFields.length) return;
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
      if (appliedCommentFields.length) {
        currentRequest.moduleId = fieldModule(appliedCommentFields[0].definition).moduleId;
        currentRequest.commentFields = appliedCommentFields.map(row => ({
          id: row.definition.id, value: row.value
        }));
      }
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
          if (saved.commentFieldSnapshotId === index?.scope?.snapshotId) {
            restoreCommentFields(saved.commentFields);
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
          package: packageFilter ? packageFilter.value : "",
          ...(appliedCommentFields.length ? {
            commentFieldSnapshotId: index.scope.snapshotId,
            commentFields: appliedCommentFields.map(row => ({
              moduleId: fieldModule(row.definition).moduleId, id: row.definition.id, value: row.value
            }))
          } : {})
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
      if (!link || (!results.contains(link) && !searchReplacement.contains(link))) return;
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
    commentFieldControls = parts.commentFields;
    searchReplacement = parts.replacement;
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
