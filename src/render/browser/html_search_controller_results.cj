protected package cjdoc.render.browser

internal let HTML_SEARCH_CONTROLLER_RESULTS_SCRIPT = """
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

    const deprecationOf = match => match?.snapshotId === index.scope.snapshotId
      ? globalThis.__CJDOC_DEPRECATION__(match.canonicalId) : undefined;
    const replacementHref = (href, kind) => {
      if (typeof href !== "string" || !href || /[\\u0000-\\u0020\\u007f<>"\\\\]/u.test(href)) return null;
      if (kind !== "api" && /^https?:\\/\\//u.test(href)) {
        try {
          const url = new URL(href);
          return url.hostname && !url.username && !url.password ? href : null;
        } catch (_) { return null; }
      }
      const relative = href.startsWith("./") ? href.slice(2) : href;
      const file = relative.split(/[?#]/u, 1)[0];
      try {
        const decoded = decodeURIComponent(file);
        if (/[\\u0000-\\u0020\\u007f<>"\\\\:]/u.test(decoded) ||
            decoded.split("/").some(part => !part || part === "." || part === "..")) return null;
      } catch (_) { return null; }
      if (kind === "api") {
        return file === relative && file.endsWith(".html")
          ? globalThis.__CJDOC_API_ROUTE__(apiRoot + file) : null;
      }
      return root + relative;
    };
    const showReplacement = match => {
      searchReplacement.replaceChildren();
      searchReplacement.hidden = true;
      const action = match ? deprecationOf(match) : undefined;
      if (!action || !["kind", "href", "label"].every(key => Object.hasOwn(action, key)) ||
          typeof action.label !== "string" || !action.label ||
          !["api", "exact", "compatible"].includes(action.kind)) return;
      const href = replacementHref(action.href, action.kind);
      if (!href) return;
      const link = createElement("a", "cj-replacement", text("Use ", "改用 "));
      link.setAttribute("href", href);
      if (action.kind !== "api") link.setAttribute("data-doc-match", action.kind);
      link.append(createElement("code", undefined, action.label));
      searchReplacement.append(link);
      searchReplacement.hidden = false;
    };

    const select = next => {
      if (!visible.length) return;
      selected = (next + visible.length) % visible.length;
      for (let position = 0; position < results.children.length; position += 1) {
        results.children[position].setAttribute("aria-selected",
          position === selected ? "true" : "false");
      }
      const active = results.children[selected];
      showReplacement(visible[selected]);
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
      head.append(name);
      if (!entry.concept && deprecationOf(match) !== undefined) {
        head.append(createElement("span", "cj-deprecation", text("Deprecated", "已弃用")));
      }
      head.append(kind);
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
      showReplacement(null);
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

"""
