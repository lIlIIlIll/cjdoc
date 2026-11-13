package cjdoc.render

// Reading-surface controllers: on-page table of contents, display settings,
// copy actions and the member browser. Each runs independently so a page
// without members or without headings still gets the rest.
internal let HTML_READING_SCRIPT = """
(() => {
  const isChinese = (document.documentElement.lang || "").toLowerCase().startsWith("zh");
  const text = (english, chinese) => isChinese ? chinese : english;

  // Outline: only reader input releases click ownership, not the jump's scroll.
  const CLICK_RELEASE_EVENTS = ["wheel", "touchstart", "keydown"];
  // Hidden document sections must disappear from the outline too.
  let syncTocVisibility = () => {};
  const initToc = () => {
    const toc = document.querySelector("[data-cjdoc-toc]");
    const content = document.querySelector("[data-cjdoc-content]");
    if (!toc || !content) return;
    const layout = toc.closest(".cj-layout");
    const tocList = toc.querySelector("ol");
    const mobileToc = document.querySelector("[data-cjdoc-mobile-toc]");
    const mobileList = mobileToc && mobileToc.querySelector("ol");
    if (!tocList) return;
    const mobileOutline = window.matchMedia("(max-width: 1180px)");
    const headings = [...content.querySelectorAll(
      "h1, h2, h3, h4, h5, h6, [data-cjdoc-toc-role='member']")].filter(heading => {
      const role = heading.dataset.cjdocTocRole;
      if (role === "member") return true;
      if (heading.closest("[data-cjdoc-member]")) return false;
      // Collapsed reference disclosures are not outline sections.
      if (heading.closest("details")) return false;
      return (role === "api-root" || role === "api" || role === "group" ||
        role === "overload" || heading.tagName === "H2" || heading.tagName === "H3");
    });
    const usedIds = new Set([...document.querySelectorAll("[id]")].map(node => node.id));
    const ensureId = (heading, index) => {
      if (heading.id) return;
      let id = (heading.textContent || "").toLowerCase().replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "") || "section-" + index;
      const base = id;
      let suffix = 2;
      while (usedIds.has(id)) { id = base + "-" + suffix; suffix += 1; }
      heading.id = id;
      usedIds.add(id);
    };
    const headingLabel = heading => {
      const explicit = heading.dataset.cjdocTocLabel;
      return (explicit || heading.textContent || "").trim().replace(/\\s+/g, " ");
    };
    const targetId = heading => {
      if (heading.dataset.cjdocTocRole === "member") {
        const member = heading.closest("details.cj-member");
        if (member && member.id) return member.id;
      }
      return heading.id;
    };
    const itemClass = heading => {
      const role = heading.dataset.cjdocTocRole;
      if (role === "member") return "cj-toc__item cj-toc__item--member";
      if (role === "group") return "cj-toc__item cj-toc__item--group";
      if (role === "api-root" || role === "api") return "cj-toc__item cj-toc__item--api";
      return "cj-toc__item";
    };
    const boundedTreeKey = value => String(value).replace(/[^A-Za-z0-9_-]+/g, "-");
    const depthOf = heading => heading.dataset.cjdocTocRole === "member"
      ? Number(heading.dataset.cjdocTocDepth || 3)
      : Number(heading.tagName.slice(1));
    const createLink = heading => {
      const link = document.createElement("a");
      link.className = "cj-toc__link";
      link.setAttribute("href", "#" + targetId(heading));
      link.dataset.tocTarget = targetId(heading);
      link.textContent = headingLabel(heading);
      return link;
    };
    // CSS draws the chevron; this supplies its accessible name.
    const createToggle = (label, children) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "cj-toc__toggle";
      button.setAttribute("aria-controls", children.id);
      const apply = expanded => {
        button.setAttribute("aria-expanded", expanded ? "true" : "false");
        button.setAttribute("aria-label",
          (expanded ? text("Collapse ", "收起 ") : text("Expand ", "展开 ")) + label);
        children.hidden = !expanded;
      };
      button.addEventListener("click", () => {
        apply(button.getAttribute("aria-expanded") !== "true");
      });
      apply(true);
      return button;
    };
    const buildChildren = prefix => {
      const list = document.createElement("ol");
      list.className = "cj-toc__children";
      list.id = "cjdoc-toc-children-" + boundedTreeKey(prefix);
      return list;
    };
    for (let index = 0; index < headings.length; index += 1) ensureId(headings[index], index);
    tocList.replaceChildren();
    // Nest under the containing kind/declaration group, else the previous section.
    // Overload titles are siblings, not another level; sectionless pages stay flat.
    const headingSet = new Set(headings);
    const containerHeading = (heading, containerSelector, titleSelector) => {
      const container = heading.closest(containerSelector);
      const title = container && container.querySelector(titleSelector);
      return title && headingSet.has(title) ? title : null;
    };
    const enclosingGroup = heading =>
      containerHeading(heading, "[data-cjdoc-member-group]", "[data-cjdoc-toc-role='group']") ||
      containerHeading(heading, "[data-cjdoc-declaration-group]", ":scope > h2");
    let section = null;
    const parentOf = new Map();
    for (const heading of headings) {
      const role = heading.dataset.cjdocTocRole;
      if (role === "api-root" || role === "api" || role === "group") {
        section = heading;
      } else if (role === "overload" || role === "member") {
        const parent = enclosingGroup(heading) || section;
        if (parent) parentOf.set(heading, parent);
      }
    }
    const withChildren = new Set(parentOf.values());
    const childLists = new Map();
    // Document order creates parent lists before their children.
    for (const heading of headings) {
      const item = document.createElement("li");
      item.className = itemClass(heading);
      item.dataset.depth = String(depthOf(heading));
      const link = createLink(heading);
      if (withChildren.has(heading)) {
        const children = buildChildren(targetId(heading));
        const row = document.createElement("div");
        row.className = "cj-toc__row";
        row.append(createToggle(headingLabel(heading), children), link);
        item.append(row, children);
        childLists.set(heading, children);
      } else {
        item.append(link);
      }
      const owner = parentOf.get(heading);
      (owner && childLists.get(owner) || tocList).append(item);
    }
    if (mobileList) {
      mobileList.replaceChildren();
      for (const heading of headings) {
        const item = document.createElement("li");
        item.className = itemClass(heading);
        item.append(createLink(heading));
        mobileList.append(item);
      }
    }
    toc.hidden = headings.length === 0;
    if (mobileToc) mobileToc.hidden = headings.length === 0;
    layout?.classList.toggle("cj-layout--with-toc", !toc.hidden);
    if (!headings.length) return;
    const links = [...tocList.querySelectorAll("a")];
    const linksByTarget = new Map(links.map(link => [link.dataset.tocTarget, link]));
    let activeLink = null;
    const setActive = targetIdValue => {
      const next = linksByTarget.get(targetIdValue) || null;
      if (next === activeLink) return;
      if (activeLink) activeLink.classList.remove("cj-toc__link--active");
      if (next) next.classList.add("cj-toc__link--active");
      activeLink = next;
    };
    // Jump targets sit above the observer band. Keep click ownership until reader
    // input or timeout instead of retaining the observer's previous entry.
    let clickedTarget = null;
    let releaseTimer = 0;
    const releaseClick = () => {
      clickedTarget = null;
      if (releaseTimer) { clearTimeout(releaseTimer); releaseTimer = 0; }
      for (const type of CLICK_RELEASE_EVENTS) {
        window.removeEventListener(type, releaseClick, true);
      }
    };
    for (const list of [tocList, mobileList]) {
      if (!list) continue;
      list.addEventListener("click", event => {
        const link = event.target && event.target.closest
          ? event.target.closest("a[data-toc-target]") : null;
        if (!link) return;
        clickedTarget = link.dataset.tocTarget;
        setActive(clickedTarget);
        for (const type of CLICK_RELEASE_EVENTS) {
          window.addEventListener(type, releaseClick, {capture: true, passive: true});
        }
        if (releaseTimer) clearTimeout(releaseTimer);
        releaseTimer = setTimeout(releaseClick, 2500);
      });
    }
    if ("IntersectionObserver" in window) {
      const observer = new IntersectionObserver(entries => {
        if (clickedTarget !== null) return;
        for (const entry of entries) {
          if (entry.isIntersecting) setActive(targetId(entry.target));
        }
      }, {rootMargin: "-18% 0px -68% 0px", threshold: 0});
      for (const heading of headings) observer.observe(heading);
    }
    setActive(targetId(headings[0]));
    // Fragments also land above the observer band: follow clicks and history.
    const syncHash = () => {
      if (!window.location.hash || window.location.hash.length <= 1) return;
      let id = window.location.hash.slice(1);
      try { id = decodeURIComponent(id); } catch (_) { /* keep raw */ }
      if (links.some(link => link.dataset.tocTarget === id)) setActive(id);
    };
    syncHash();
    window.addEventListener("hashchange", syncHash);
    const byTarget = new Map(headings.map(heading => [targetId(heading), heading]));
    const outline = [tocList, mobileList].filter(Boolean).flatMap(list =>
      [...list.querySelectorAll("[data-toc-target]")].map(link => ({
        list, link, item: link.closest("li"), heading: byTarget.get(link.dataset.tocTarget)
      })));
    syncTocVisibility = () => {
      const visible = headings.filter(heading => !heading.closest("[hidden]"));
      const visibleIds = new Set(visible.map(targetId));
      const activeList = mobileOutline.matches && mobileList || tocList;
      for (const {list, link, item, heading} of outline) {
        if (list !== activeList) continue;
        if (item) item.hidden = !visibleIds.has(link.dataset.tocTarget);
        // Filtering changes group counts, not member signatures.
        if (heading && heading.dataset.cjdocTocRole !== "member") {
          const label = headingLabel(heading);
          if (link.textContent !== label) link.textContent = label;
        }
      }
      const active = tocList.querySelector(".cj-toc__link--active");
      if (active && !visibleIds.has(active.dataset.tocTarget) && visible.length) {
        setActive(targetId(visible[0]));
      }
      toc.hidden = visible.length === 0;
      if (mobileToc) mobileToc.hidden = visible.length === 0;
      layout?.classList.toggle("cj-layout--with-toc", !toc.hidden);
    };
    mobileOutline.addEventListener("change", syncTocVisibility);
  };

  // Display settings: first-open construction leaves untouched pages dialog-free.
  // Header labels use stable options before any option buttons exist.
  const THEMES = ["system", "light", "dark", "paper", "ocean", "forest", "terminal", "violet"];
  const FONTS = ["system", "serif", "mono-ui"];
  const SIZES = ["s", "m", "l"];
  const THEME_OPTIONS = [["system", "System", "跟随系统"], ["light", "Light", "浅色"],
    ["dark", "Dark", "深色"], ["paper", "Paper", "纸色"], ["ocean", "Ocean", "海洋"],
    ["forest", "Forest", "森林"], ["terminal", "Terminal", "终端"], ["violet", "Violet", "紫罗兰"]];
  const FONT_OPTIONS = [["system", "System", "系统"], ["serif", "Serif", "衬线"],
    ["mono-ui", "Monospace", "等宽"]];
  const SIZE_OPTIONS = [["s", "S", "S"], ["m", "M", "M"], ["l", "L", "L"]];
  // Fixed close glyph; CSS owns its size.
  const settingsIcon = () => {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    for (const [key, value] of Object.entries({class: "cj-icon", width: "16", height: "16",
      viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": "1.8",
      "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true",
      focusable: "false"})) {
      svg.setAttribute(key, value);
    }
    const shape = document.createElementNS(svg.namespaceURI, "path");
    shape.setAttribute("d", "M6 6l12 12M18 6 6 18");
    svg.append(shape);
    return svg;
  };
  const settingsGroup = (english, chinese, options, attribute, themed) => {
    const group = document.createElement("fieldset");
    group.className = "cj-settings__group";
    const legend = document.createElement("legend");
    legend.className = "cj-settings__legend";
    legend.textContent = text(english, chinese);
    const list = document.createElement("div");
    list.className = themed
      ? "cj-settings__options cj-settings__options--themes" : "cj-settings__options";
    for (const [value, optionEnglish, optionChinese] of options) {
      const button = document.createElement("button");
      button.className = "cj-settings__option";
      button.type = "button";
      button.setAttribute(attribute, value);
      button.setAttribute("aria-pressed", "false");
      if (themed) {
        const swatch = document.createElement("span");
        swatch.className = "cj-settings__swatch";
        swatch.setAttribute("data-cjdoc-swatch", value);
        swatch.setAttribute("aria-hidden", "true");
        button.append(swatch);
      }
      const name = document.createElement("span");
      name.textContent = text(optionEnglish, optionChinese);
      button.append(name);
      list.append(button);
    }
    group.append(legend, list);
    return group;
  };
  const buildSettingsDialog = () => {
    const dialog = document.createElement("dialog");
    dialog.id = "cjdoc-theme-popover";
    dialog.className = "cj-settings";
    dialog.setAttribute("data-cjdoc-theme-popover", "");
    dialog.setAttribute("aria-labelledby", "cjdoc-settings-title");
    const head = document.createElement("div");
    head.className = "cj-settings__head";
    const title = document.createElement("h2");
    title.id = "cjdoc-settings-title";
    title.className = "cj-settings__title";
    title.textContent = text("Display", "显示");
    const closeButton = document.createElement("button");
    closeButton.className = "cj-button cj-button--icon";
    closeButton.type = "button";
    closeButton.setAttribute("data-cjdoc-theme-close", "");
    closeButton.setAttribute("aria-label", text("Close", "关闭"));
    closeButton.append(settingsIcon());
    head.append(title, closeButton);
    dialog.append(head,
      settingsGroup("Theme", "主题", THEME_OPTIONS, "data-cjdoc-theme-value", true),
      settingsGroup("Font", "字体", FONT_OPTIONS, "data-cjdoc-font-value", false),
      settingsGroup("Text size", "字号", SIZE_OPTIONS, "data-cjdoc-size-value", false));
    const hint = document.createElement("p");
    hint.className = "cj-settings__hint";
    hint.textContent = text("System follows your device appearance.",
      "跟随系统会采用设备的外观设置。");
    dialog.append(hint);
    return dialog;
  };
  const readReader = () => {
    try {
      const value = JSON.parse(localStorage.getItem("cjdoc-reader") || "{}");
      return value && typeof value === "object" ? value : {};
    } catch (_) { return {}; }
  };
  const writeReader = (next) => {
    try { localStorage.setItem("cjdoc-reader", JSON.stringify(next)); } catch (_) { /* optional */ }
  };
  const initSettings = () => {
    const root = document.documentElement;
    const trigger = document.querySelector("[data-cjdoc-theme-toggle]");
    if (!trigger) return;
    const label = document.querySelector("[data-cjdoc-theme-label]");
    const persistence = globalThis.__CJDOC_THEME__;
    const themeLabels = new Map(THEME_OPTIONS.map(([value, english, chinese]) =>
      [value, text(english, chinese)]));
    let dialog = null;
    let themeButtons = [];
    let fontButtons = [];
    let sizeButtons = [];
    const currentTheme = () => {
      const value = root.dataset.theme;
      return THEMES.includes(value) ? value : "system";
    };
    const currentFont = () => FONTS.includes(root.dataset.cjFont) ? root.dataset.cjFont : "system";
    const currentSize = () => SIZES.includes(root.dataset.cjSize) ? root.dataset.cjSize : "m";
    // Sync persisted labels before creation, and option state after creation.
    const sync = () => {
      const theme = currentTheme();
      for (const button of themeButtons) {
        button.setAttribute("aria-pressed",
          button.dataset.cjdocThemeValue === theme ? "true" : "false");
      }
      for (const button of fontButtons) {
        button.setAttribute("aria-pressed",
          button.dataset.cjdocFontValue === currentFont() ? "true" : "false");
      }
      for (const button of sizeButtons) {
        button.setAttribute("aria-pressed",
          button.dataset.cjdocSizeValue === currentSize() ? "true" : "false");
      }
      if (label) label.textContent = text("Theme: ", "主题：") +
        (themeLabels.get(theme) || themeLabels.get("system"));
    };
    const applyTheme = next => {
      if (!THEMES.includes(next)) return;
      if (next === "system") root.removeAttribute("data-theme");
      else root.setAttribute("data-theme", next);
      if (persistence && typeof persistence.persist === "function") persistence.persist(next);
      else try { localStorage.setItem("cjdoc-theme", next); } catch (_) { /* optional */ }
      sync();
    };
    const applyFont = next => {
      if (!FONTS.includes(next)) return;
      if (next === "system") root.removeAttribute("data-cj-font");
      else root.setAttribute("data-cj-font", next);
      const reader = readReader();
      reader.font = next;
      writeReader(reader);
      sync();
    };
    const applySize = next => {
      if (!SIZES.includes(next)) return;
      if (next === "m") root.removeAttribute("data-cj-size");
      else root.setAttribute("data-cj-size", next);
      const reader = readReader();
      reader.size = next;
      writeReader(reader);
      sync();
    };
    // Create/bind once; associate aria-controls only with a real dialog.
    const ensureDialog = () => {
      if (dialog) return dialog;
      const created = buildSettingsDialog();
      // Preserve the non-modal fallback's original placement.
      const header = trigger.closest("header");
      if (header && header.parentNode) header.after(created);
      else document.body.append(created);
      const closeButton = created.querySelector("[data-cjdoc-theme-close]");
      themeButtons = [...created.querySelectorAll("[data-cjdoc-theme-value]")];
      fontButtons = [...created.querySelectorAll("[data-cjdoc-font-value]")];
      sizeButtons = [...created.querySelectorAll("[data-cjdoc-size-value]")];
      if (closeButton) closeButton.addEventListener("click", () => close(true));
      created.addEventListener("close", () => {
        trigger.setAttribute("aria-expanded", "false");
        if (typeof trigger.focus === "function") trigger.focus();
      });
      created.addEventListener("click", event => {
        if (event.target === created) close(true);
      });
      for (const button of themeButtons) {
        button.addEventListener("click", () => applyTheme(button.dataset.cjdocThemeValue));
      }
      for (const button of fontButtons) {
        button.addEventListener("click", () => applyFont(button.dataset.cjdocFontValue));
      }
      for (const button of sizeButtons) {
        button.addEventListener("click", () => applySize(button.dataset.cjdocSizeValue));
      }
      trigger.setAttribute("aria-controls", created.id);
      dialog = created;
      sync();
      return dialog;
    };
    const open = () => {
      const surface = ensureDialog();
      trigger.setAttribute("aria-expanded", "true");
      if (typeof surface.showModal === "function" && !surface.open) surface.showModal();
      else surface.setAttribute("open", "");
      const active = surface.querySelector("[aria-pressed='true']");
      if (active && typeof active.focus === "function") active.focus();
    };
    const close = (restoreFocus = true) => {
      trigger.setAttribute("aria-expanded", "false");
      if (!dialog) return;
      if (typeof dialog.close === "function" && dialog.open) dialog.close();
      else dialog.removeAttribute("open");
      if (restoreFocus && typeof trigger.focus === "function") trigger.focus();
    };
    // The drawer makes the header trigger inert, so it cannot coexist with settings.
    // Closing must leave no inert surface.
    trigger.hidden = false;
    trigger.addEventListener("click", open);
    sync();
  };

  // Copy actions.
  const copyText = async value => {
    if (navigator.clipboard && window.isSecureContext) {
      try { await navigator.clipboard.writeText(value); return true; } catch (_) { /* fallback */ }
    }
    const previousFocus = document.activeElement;
    const area = document.createElement("textarea");
    area.value = value;
    area.setAttribute("readonly", "");
    area.className = "cj-sr-only";
    document.body.append(area);
    area.select();
    let copied = false;
    // Textarea selection normalizes CRLF; the real copy event gets original bytes.
    const preserveOriginal = event => {
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
  const flashCopyState = (button, copied) => {
    button.dataset.cjdocCopyState = copied ? "copied" : "failed";
    window.setTimeout(() => { delete button.dataset.cjdocCopyState; }, 1500);
  };
  const initCopy = () => {
    for (const button of document.querySelectorAll("[data-cjdoc-copy-link]")) {
      const iconOnly = !button.textContent || !button.textContent.trim();
      const label = button.getAttribute("aria-label") || button.textContent || "";
      const status = button.parentElement
        ? button.parentElement.querySelector("[data-cjdoc-copy-status]") : null;
      button.addEventListener("click", async () => {
        let url = button.dataset.cjdocCopyLink || "";
        try { url = new URL(url, window.location.href).href; } catch (_) { /* keep raw */ }
        const copied = await copyText(url);
        const message = copied ? text("Link copied", "链接已复制")
          : text("Select and copy the link", "请选择并复制链接");
        flashCopyState(button, copied);
        if (iconOnly) {
          button.setAttribute("aria-label", message);
          button.setAttribute("title", message);
          if (status) status.textContent = message;
        } else {
          const span = button.querySelector("span");
          if (span) span.textContent = message;
          else button.textContent = message;
          if (status) status.textContent = message;
        }
        if (!copied) {
          let field = button.parentElement
            ? button.parentElement.querySelector("[data-cjdoc-copy-link-fallback]") : null;
          if (!field) {
            field = document.createElement("input");
            field.type = "text";
            field.readOnly = true;
            field.className = "cj-input";
            field.dataset.cjdocCopyLinkFallback = "";
            field.setAttribute("aria-label", text("Link address", "链接地址"));
            button.insertAdjacentElement("afterend", field);
          }
          field.value = url;
          field.focus();
          field.select();
        }
        window.setTimeout(() => {
          if (iconOnly) {
            button.setAttribute("aria-label", label);
            button.setAttribute("title", label);
            if (status) status.textContent = "";
          }
        }, 1800);
      });
    }
    for (const code of document.querySelectorAll("pre > code")) {
      const pre = code.parentElement;
      if (!pre || pre.querySelector("[data-cjdoc-copy]")) continue;
      const button = document.createElement("button");
      button.type = "button";
      button.className = "cj-button cj-button--quiet cj-code__copy";
      button.setAttribute("data-cjdoc-copy", "");
      button.setAttribute("aria-label", text("Copy code", "复制代码"));
      button.setAttribute("title", text("Copy code", "复制代码"));
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      for (const [key, value] of Object.entries({class: "cj-icon", viewBox: "0 0 24 24",
        fill: "none", stroke: "currentColor", "stroke-width": "1.8", "aria-hidden": "true"})) {
        svg.setAttribute(key, value);
      }
      const front = document.createElementNS(svg.namespaceURI, "rect");
      for (const [key, value] of Object.entries({x: "8", y: "8", width: "12", height: "12", rx: "2"})) {
        front.setAttribute(key, value);
      }
      const back = document.createElementNS(svg.namespaceURI, "path");
      back.setAttribute("d", "M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2");
      svg.append(front, back);
      const caption = document.createElement("span");
      caption.textContent = text("Copy", "复制");
      button.append(svg, caption);
      pre.append(button);
      button.addEventListener("click", async () => {
        const original = code.getAttribute("data-cjdoc-source");
        let value = code.textContent || "";
        if (original !== null) {
          try { value = JSON.parse(original); } catch (_) { /* keep text */ }
        }
        const copied = await copyText(value);
        flashCopyState(button, copied);
        const message = copied ? text("Copied", "已复制") : text("Copy code", "复制代码");
        caption.textContent = copied ? text("Copied", "已复制") : text("Copy", "复制");
        button.setAttribute("aria-label", message);
        button.setAttribute("title", message);
        setTimeout(() => {
          caption.textContent = text("Copy", "复制");
          button.setAttribute("aria-label", text("Copy code", "复制代码"));
          button.setAttribute("title", text("Copy code", "复制代码"));
        }, 1500);
      });
    }
  };

  // Member browser.
  const initMembers = () => {
    const browser = document.querySelector("[data-cjdoc-member-browser]");
    if (!browser) return;
    const kernel = globalThis.cjdocSearch;
    const index = globalThis.__CJDOC_SEARCH_INDEX__;
    const rows = [...document.querySelectorAll("[data-cjdoc-member]")];
    const memberFilter = kernel?.createEntryFilter(index, rows.map(row => row.dataset.memberSymbolId));
    const groups = [...document.querySelectorAll("[data-cjdoc-member-group]")];
    const overloads = [...document.querySelectorAll("[data-cjdoc-overload-group]")];
    const filter = document.querySelector("[data-cjdoc-member-filter]");
    const origin = document.querySelector("[data-cjdoc-member-origin]");
    const filterToggle = document.querySelector("[data-cjdoc-member-filter-toggle]");
    const filterFields = document.querySelector("#cjdoc-member-filter-fields");
    const status = document.querySelector("[data-cjdoc-member-filter-status]");
    const expand = document.querySelector("[data-cjdoc-members-expand]");
    const collapse = document.querySelector("[data-cjdoc-members-collapse]");
    let notice = "";
    const syncActions = () => {
      const visible = rows.filter(row => !row.hidden);
      if (expand) expand.disabled = !visible.some(row => !row.open);
      if (collapse) collapse.disabled = !visible.some(row => row.open);
    };
    // CSS reads aria-expanded, avoiding stale touch-menu state after resizing.
    const closeActionMenus = (restoreFocus = false) => {
      let closed = null;
      for (const toggle of document.querySelectorAll('[data-cjdoc-member-actions-toggle][aria-expanded="true"]')) {
        toggle.setAttribute("aria-expanded", "false");
        closed = closed || toggle;
      }
      if (restoreFocus && closed) closed.focus();
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
      let matching = emptyIds;
      if (!error) {
        const request = {query: parsed.query, filters: parsed.filters};
        if (parsed.tags.length) request.tags = parsed.tags;
        const projection = memberFilter(request);
        if (projection.status !== "ok") error = projection.errorCode || "search_index_invalid";
        else matching = new Set(projection.canonicalIds);
      }
      const active = Boolean(parsed.query || parsed.filters.length || parsed.tags.length);
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
        row.hidden = !matches;
        const wrapper = row.closest(".cj-member-row");
        if (wrapper) wrapper.hidden = !matches;
        if (matches) visible += 1;
      }
      for (const group of overloads) {
        const total = Number(group.dataset.overloadTotal);
        const matches = [...group.querySelectorAll("[data-cjdoc-member]")]
          .filter(row => !row.hidden).length;
        group.hidden = matches === 0;
        const count = group.querySelector("[data-cjdoc-overload-count]");
        if (count && Number.isFinite(total) && total > 0) {
          count.textContent = matches === total
            ? (isChinese ? total + " 个重载" : total + " overloads")
            : (isChinese ? matches + " / " + total + " 个重载"
              : matches + " of " + total + " overloads");
        }
      }
      for (const group of groups) {
        const members = [...group.querySelectorAll("[data-cjdoc-member]")];
        const matches = members.filter(row => !row.hidden).length;
        group.hidden = matches === 0;
        const count = group.querySelector(".cj-member-group__count");
        if (count) {
          const value = matches === members.length ? String(members.length)
            : matches + " / " + members.length;
          count.textContent = isChinese ? value + " 个成员"
            : value + (members.length === 1 ? " member" : " members");
        }
      }
      for (const role of document.querySelectorAll("[data-cjdoc-declaration-group]")) {
        const members = [...role.querySelectorAll("[data-cjdoc-member]")];
        const matches = members.filter(row => !row.hidden).length;
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
      // CSS unfolds fields on wide layouts and folds them behind this control.
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
    for (const actions of document.querySelectorAll("[data-cjdoc-member-actions]")) {
      const toggle = actions.querySelector("[data-cjdoc-member-actions-toggle]");
      if (!toggle) continue;
      toggle.addEventListener("click", () => {
        const opening = toggle.getAttribute("aria-expanded") !== "true";
        closeActionMenus();
        if (!opening) return;
        toggle.setAttribute("aria-expanded", "true");
      });
      actions.addEventListener("keydown", event => {
        if (event.key !== "Escape") return;
        if (toggle.getAttribute("aria-expanded") !== "true") return;
        event.preventDefault();
        closeActionMenus(true);
      });
      actions.addEventListener("focusout", event => {
        if (!actions.contains(event.relatedTarget)) closeActionMenus();
      });
    }
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
    // Persist per-page state, but an explicitly chosen hash wins over it.
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
    // History restores filters; fresh hashes reveal their target.
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
    // Restored open/filter state already wins over the restored URL's hash.
    if (!restored) revealHashTarget(true);
    window.addEventListener("hashchange", () => revealHashTarget(true));
    // Same-fragment clicks fire no hashchange; still unfilter and reopen.
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

  initToc();
  initSettings();
  initCopy();
  initMembers();
})();
"""
