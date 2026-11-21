package cjdoc.render

// Reading-surface controllers: on-page table of contents, display settings,
// copy actions and the member browser. Each runs independently so a page
// without members or without headings still gets the rest. Outline clicks and
// fragments own the active highlight until reader input releases it. Overloads
// stay siblings. Member history restores filters before considering the hash;
// copy fallback uses the clipboard event to preserve bytes lost by textarea
// line-ending normalization.
internal let HTML_READING_SCRIPT = """
(() => {
  const isChinese = (document.documentElement.lang || "").toLowerCase().startsWith("zh");
  const text = (english, chinese) => isChinese ? chinese : english;
  const find = selector => document.querySelector(selector);
  const all = selector => document.querySelectorAll(selector);
  const element = (tag, className, caption) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (caption !== undefined) node.textContent = caption;
    return node;
  };
  const attrs = (node, attributes) => {
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
    return node;
  };
  const svg = (tag, attributes) => attrs(document.createElementNS("http://www.w3.org/2000/svg", tag), attributes);
  const icon = () => svg("svg", {class: "cj-icon", viewBox: "0 0 24 24",
    fill: "none", stroke: "currentColor", "stroke-width": "1.8", "aria-hidden": "true"});

  const CLICK_RELEASE_EVENTS = ["wheel", "touchstart", "keydown"];
  let syncTocVisibility = () => {};
  const initToc = () => {
    const toc = find("[data-cjdoc-toc]");
    const content = find("[data-cjdoc-content]");
    if (!toc || !content) return;
    const layout = toc.closest(".cj-layout");
    const tocList = toc.querySelector("ol");
    const mobileToc = find("[data-cjdoc-mobile-toc]");
    const mobileList = mobileToc && mobileToc.querySelector("ol");
    if (!tocList) return;
    const mobileOutline = window.matchMedia("(max-width: 1180px)");
    const headings = [...content.querySelectorAll(
      "h1, h2, h3, h4, h5, h6, [data-cjdoc-toc-role='member'], [data-cjdoc-toc-role='entry']")].filter(heading => {
      const role = heading.dataset.cjdocTocRole;
      if (role === "member") return true;
      if (role === "entry") return Boolean(heading.id) && !heading.closest("details");
      if (heading.closest("[data-cjdoc-member]")) return false;
      if (heading.closest("details")) return false;
      return (role === "api-root" || role === "api" || role === "group" ||
        role === "overload" || heading.tagName === "H2" || heading.tagName === "H3");
    });
    const usedIds = new Set(Array.from(all("[id]"), node => node.id));
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
    const headingLabel = heading =>
      (heading.dataset.cjdocTocLabel || heading.textContent || "").trim().replace(/\\s+/g, " ");
    // Reuse the primary label's breaks without copying links, badges or markup.
    const appendEntryLabel = (link, entry) => {
      const code = entry.querySelector("a[data-cjdoc-api-link] > code");
      if (!code) return;
      for (const child of code.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) link.append(child.data);
        else if (child.nodeName === "WBR") link.append(element("wbr"));
      }
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
      if (role === "entry") return "cj-toc__item cj-toc__item--entry";
      if (role === "group") return "cj-toc__item cj-toc__item--group";
      if (role === "api-root" || role === "api") return "cj-toc__item cj-toc__item--api";
      return "cj-toc__item";
    };
    const boundedTreeKey = value => String(value).replace(/[^A-Za-z0-9_-]+/g, "-");
    // An overload label and its signatures are peers in the reading outline.
    // Their semantic heading levels in the body do not set the outline depth.
    const depthOf = heading => {
      const parent = parentOf.get(heading);
      if (parent) return depthOf(parent) + 1;
      const role = heading.dataset.cjdocTocRole;
      if (role === "member" || role === "entry") return Number(heading.dataset.cjdocTocDepth || 3);
      return Number(heading.tagName.slice(1));
    };
    const createLink = heading => {
      const id = targetId(heading);
      const entry = heading.dataset.cjdocTocRole === "entry";
      const link = element("a", "cj-toc__link", entry ? undefined : headingLabel(heading));
      if (entry) appendEntryLabel(link, heading);
      link.setAttribute("href", "#" + id);
      link.dataset.tocTarget = id;
      return link;
    };
    const createToggle = (label, children) => {
      const button = element("button", "cj-toc__toggle");
      button.type = "button";
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
      const list = element("ol", "cj-toc__children");
      list.id = "cjdoc-toc-children-" + boundedTreeKey(prefix);
      return list;
    };
    for (let index = 0; index < headings.length; index += 1) ensureId(headings[index], index);
    tocList.replaceChildren();
    const headingSet = new Set(headings);
    const containerHeading = (heading, containerSelector, titleSelector) => {
      const container = heading.closest(containerSelector);
      const title = container && container.querySelector(titleSelector);
      return title && headingSet.has(title) ? title : null;
    };
    const enclosingGroup = heading =>
      containerHeading(heading, "[data-cjdoc-member-group]", "[data-cjdoc-toc-role='group']") ||
      containerHeading(heading, "[data-cjdoc-declaration-group]", ":scope > h2");
    // A declaration entry belongs to the visible kind heading that states its
    // kind; when that heading is merged into its author group, the group title is
    // the parent. A choice page has neither, so its `#api-options` heading wins.
    const enclosingEntry = heading =>
      containerHeading(heading, ".cj-decl-group", ":scope > [data-cjdoc-toc-role='group']") ||
      enclosingGroup(heading);
    let section = null;
    const parentOf = new Map();
    for (const heading of headings) {
      const role = heading.dataset.cjdocTocRole;
      if (role === "api-root" || role === "api" || role === "group") {
        section = heading;
      } else if (role === "overload" || role === "member" || role === "entry") {
        const parent = (role === "entry" ? enclosingEntry(heading) : enclosingGroup(heading)) || section;
        if (parent) parentOf.set(heading, parent);
      }
    }
    const withChildren = new Set(parentOf.values());
    const childLists = new Map();
    for (const heading of headings) {
      const item = element("li", itemClass(heading));
      item.dataset.depth = String(depthOf(heading));
      const link = createLink(heading);
      if (withChildren.has(heading)) {
        const children = buildChildren(targetId(heading));
        const row = element("div", "cj-toc__row");
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
        const item = element("li", itemClass(heading));
        item.append(createLink(heading));
        mobileList.append(item);
      }
    }
    toc.hidden = headings.length === 0;
    if (mobileToc) mobileToc.hidden = headings.length === 0;
    layout?.classList.toggle("cj-layout--with-toc", !toc.hidden);
    if (!headings.length) return;
    // One target can be listed by both the desktop and the mobile outline, so
    // the active state and `aria-current` are applied to every copy.
    const linksByTarget = new Map();
    for (const list of [tocList, mobileList]) {
      if (!list) continue;
      for (const link of list.querySelectorAll("a[data-toc-target]")) {
        const target = link.dataset.tocTarget;
        const links = linksByTarget.get(target);
        if (links) links.push(link); else linksByTarget.set(target, [link]);
      }
    }
    let activeLinks = [];
    const setActive = targetIdValue => {
      const next = linksByTarget.get(targetIdValue) || [];
      if (next.length && activeLinks.length && next[0] === activeLinks[0]) return;
      for (const link of activeLinks) {
        link.classList.remove("cj-toc__link--active");
        link.removeAttribute("aria-current");
      }
      for (const link of next) {
        link.classList.add("cj-toc__link--active");
        link.setAttribute("aria-current", "location");
      }
      activeLinks = next;
    };
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
          if (entry.isIntersecting && !entry.target.closest("[hidden]")) setActive(targetId(entry.target));
        }
      }, {rootMargin: "-18% 0px -68% 0px", threshold: 0});
      for (const heading of headings) observer.observe(heading);
    }
    setActive(targetId(headings[0]));
    const syncHash = () => {
      if (!window.location.hash || window.location.hash.length <= 1) return;
      let id = window.location.hash.slice(1);
      try { id = decodeURIComponent(id); } catch (_) { /* keep raw */ }
      if (linksByTarget.has(id)) setActive(id);
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
        const hidden = !visibleIds.has(link.dataset.tocTarget);
        if (item && item.hidden !== hidden) item.hidden = hidden;
        const role = heading?.dataset.cjdocTocRole;
        if (heading && role !== "member" && role !== "entry") {
          const label = headingLabel(heading);
          if (link.textContent !== label) link.textContent = label;
        }
      }
      if (activeLinks.length && !visibleIds.has(activeLinks[0].dataset.tocTarget) && visible.length) {
        setActive(targetId(visible[0]));
      }
      toc.hidden = visible.length === 0;
      if (mobileToc) mobileToc.hidden = visible.length === 0;
      layout?.classList.toggle("cj-layout--with-toc", !toc.hidden);
    };
    mobileOutline.addEventListener("change", syncTocVisibility);
  };

  const EXAMPLE_SELECTOR = "details[data-cjdoc-example]";
  const setDisclosures = (selector, open, fragment = null) => {
    for (const details of all(selector)) {
      details.open = open || details === fragment;
    }
  };
  const exampleFragmentTarget = () => {
    if (!window.location.hash) return null;
    try {
      const id = decodeURIComponent(window.location.hash.slice(1));
      return document.getElementById(id)?.closest(EXAMPLE_SELECTOR) || null;
    } catch (_) { return null; }
  };
  const restoreNotices = [];
  const groupNotices = value => {
    if (value !== "grouped") {
      for (const restore of restoreNotices.splice(0)) restore();
      return;
    }
    if (restoreNotices.length) return;
    for (const scope of all("[data-cjdoc-api-intro]")) {
      const groups = Object.create(null);
      for (const box of scope.querySelectorAll(":scope > :is(.cj-description,[data-cjdoc-notice]) .cj-admonition")) {
        if (!box.parentElement.closest("aside,blockquote,li,table"))
          (groups[box.dataset.admonitionLevel] ??= []).push(box);
      }
      for (const same of Object.values(groups)) {
        if (same.length < 2) continue;
        const first = same[0];
        const combined = first.cloneNode();
        const list = element("ul", "cj-admonition__body cj-prose");
        combined.append(first.firstElementChild.cloneNode(true), list);
        (first.closest("[data-cjdoc-notice]") || first).before(combined);
        for (const box of same) {
          // Move the authored subtree, including its field anchor and language.
          const unit = box.closest("[data-cjdoc-notice]") || box;
          const original = document.createComment("");
          const item = element("li");
          const body = box.lastElementChild;
          if (unit === box) item.lang = box.closest("[lang]").lang;
          else box.replaceWith(body);
          unit.replaceWith(original);
          item.append(unit === box ? body : unit);
          list.append(item);
          restoreNotices.push(() => {
            body.replaceWith(box);
            box.append(body);
            original.replaceWith(unit);
          });
        }
        restoreNotices.push(() => combined.remove());
      }
    }
  };
  const disclosureOptions = [["expanded", "Expanded", "展开"], ["collapsed", "Collapsed", "折叠"]];
  const displaySettings = [
    {key: "theme", name: "theme", title: ["Theme", "主题"], root: "data-theme", fallback: "system",
      options: [["system", "System", "跟随系统"], ["light", "Light", "浅色"],
        ["dark", "Dark", "深色"], ["paper", "Paper", "纸色"], ["ocean", "Ocean", "海洋"],
        ["forest", "Forest", "森林"], ["terminal", "Terminal", "终端"], ["violet", "Violet", "紫罗兰"]]},
    {key: "font", name: "font", title: ["Font", "字体"], root: "data-cj-font", fallback: "system",
      options: [["system", "System", "系统"], ["serif", "Serif", "衬线"], ["mono-ui", "Monospace", "等宽"]]},
    {key: "size", name: "size", title: ["Text size", "字号"], root: "data-cj-size",
      fallback: "m", options: [["s", "S", "S"], ["m", "M", "M"], ["l", "L", "L"]]},
    {key: "codeLines", name: "code-lines", title: ["Long code lines", "代码块长行"],
      root: "data-cj-code-lines", fallback: "scroll",
      options: [["scroll", "Scroll horizontally", "横向滚动"], ["wrap", "Wrap", "自动换行"]],
      help: ["cjdoc-code-lines-help", "Only changes how code is shown, not copied text or expected output.",
        "只改变代码显示，不改变复制内容或预期输出。"]},
    {key: "examples", name: "example", title: ["Examples by default", "示例默认状态"],
      fallback: "expanded", options: disclosureOptions,
      apply: (value, initial) =>
        setDisclosures(EXAMPLE_SELECTOR, value === "expanded", initial ? exampleFragmentTarget() : null)},
    {key: "longOutput", name: "long-output", title: ["Long output by default", "长输出默认状态"],
      fallback: "collapsed", options: disclosureOptions,
      apply: value => setDisclosures("details.cj-example-pair__disclosure", value === "expanded"),
      help: ["cjdoc-long-output-help", "Does not change the whole example.", "不改变整个示例的状态。"]},
    {key: "apiNotices", name: "api-notices", title: ["API notices", "API 提示"],
      fallback: "separate", options: [["separate", "Show separately", "逐条显示"],
        ["grouped", "Group by type", "按类型合并"]], apply: groupNotices},
  ];
  const [theme] = displaySettings;
  const optionAttr = setting => "data-cjdoc-" + setting.name + "-value";
  const settingsGroup = (setting, buttons) => {
    const {title, options, help} = setting;
    const group = element("fieldset", "cj-settings__group");
    const themed = setting === theme;
    const list = element("div", "cj-settings__options" + (themed ? " cj-settings__options--themes" : ""));
    group.append(element("legend", "cj-settings__legend", text(...title)), list);
    for (const [value, ...caption] of options) {
      const button = attrs(element("button", "cj-settings__option"), {type: "button", [optionAttr(setting)]: value});
      buttons.set(button, {setting, value});
      if (themed) {
        button.append(attrs(element("span", "cj-settings__swatch"), {"data-cjdoc-swatch": value, "aria-hidden": "true"}));
      }
      button.append(element("span", "", text(...caption)));
      list.append(button);
    }
    if (help) {
      const [id, ...caption] = help;
      group.setAttribute("aria-describedby", id);
      group.append(attrs(element("p", "cj-settings__description", text(...caption)), {id}));
    }
    if (themed) {
      group.append(element("p", "cj-settings__hint",
        text("System follows your device appearance.", "跟随系统会采用设备的外观设置。")));
    }
    return group;
  };
  const buildSettingsDialog = buttons => {
    const title = element("h2", "cj-settings__title", text("Display", "显示"));
    title.id = "cjdoc-settings-title";
    const dialog = attrs(element("dialog", "cj-settings"), {
      id: "cjdoc-theme-popover", "data-cjdoc-theme-popover": "", "aria-labelledby": title.id
    });
    const close = attrs(element("button", "cj-button cj-button--icon"), {
      type: "button", "data-cjdoc-theme-close": "", "aria-label": text("Close", "关闭")
    });
    const glyph = attrs(icon(), {width: "16", height: "16", "stroke-linecap": "round",
      "stroke-linejoin": "round", focusable: "false"});
    glyph.append(svg("path", {d: "M6 6l12 12M18 6 6 18"}));
    close.append(glyph);
    const head = element("div", "cj-settings__head");
    head.append(title, close);
    dialog.append(head);
    for (const setting of displaySettings) dialog.append(settingsGroup(setting, buttons));
    const reset = attrs(element("button", "cj-button", text("Reset display settings", "恢复默认设置")), {
      type: "button", "data-cjdoc-reset-display": ""
    });
    const status = attrs(element("span"), {role: "status"});
    const actions = element("div", "cj-settings__actions");
    actions.append(reset, status);
    dialog.append(actions);
    return {dialog, close, reset, status};
  };
  const readerKey = "cjdoc-reader";
  const readReader = () => {
    try {
      const value = JSON.parse(localStorage.getItem(readerKey) || "{}");
      return value && typeof value === "object" && !Array.isArray(value) ? value : {};
    } catch (_) { return {}; }
  };
  const initSettings = () => {
    const root = document.documentElement;
    const trigger = find("[data-cjdoc-theme-toggle]");
    if (!trigger) return;
    const label = find("[data-cjdoc-theme-label]");
    const persistence = globalThis.__CJDOC_THEME__;
    const reader = readReader();
    const values = Object.create(null);
    for (const {key, root: attribute, options, fallback, apply} of displaySettings) {
      const candidate = attribute ? root.getAttribute(attribute) : reader[key];
      const value = options.some(([allowed]) => allowed === candidate) ? candidate : fallback;
      values[key] = value;
      if (value !== fallback) apply?.(value, true);
    }
    window.addEventListener("hashchange", () => {
      const example = exampleFragmentTarget();
      if (example) example.open = true;
    });
    let dialog;
    let buttons;
    const sync = () => {
      for (const [button, {setting, value}] of buttons || []) {
        button.setAttribute("aria-pressed", String(value === values[setting.key]));
      }
      if (label) {
        const [, ...caption] = theme.options.find(([value]) => value === values.theme);
        label.textContent = text("Theme: ", "主题：") + text(...caption);
      }
    };
    const apply = ({key, root: attribute, fallback, apply: present}, value) => {
      values[key] = value;
      if (attribute) {
        if (value === fallback) root.removeAttribute(attribute);
        else root.setAttribute(attribute, value);
      }
      present?.(value);
    };
    const persistTheme = value => {
      if (persistence?.persist) persistence.persist(value);
      else try { localStorage.setItem("cjdoc-theme", value); } catch (_) { /* optional */ }
    };
    const save = (setting, value) => {
      if (setting === theme) persistTheme(value);
      else try {
        const next = readReader();
        next[setting.key] = value;
        localStorage.setItem(readerKey, JSON.stringify(next));
      } catch (_) { /* optional */ }
    };
    const ensureDialog = () => {
      if (dialog) return dialog;
      buttons = new Map();
      const {dialog: surface, close: dismiss, reset, status} = buildSettingsDialog(buttons);
      dialog = surface;
      const header = trigger.closest("header");
      if (header?.parentNode) header.after(dialog);
      else document.body.append(dialog);
      trigger.setAttribute("aria-controls", dialog.id);
      dialog.addEventListener("cancel", event => {
        event.preventDefault();
        close();
      });
      dialog.addEventListener("click", event => {
        const button = event.target.closest?.("button");
        if (button === dismiss || event.target === dialog) close();
        else if (button === reset) {
          for (const setting of displaySettings) apply(setting, setting.fallback);
          try { localStorage.removeItem(readerKey); } catch (_) { /* optional */ }
          persistTheme(theme.fallback);
          sync();
          reset.focus();
          status.textContent = text("Display settings reset.", "已恢复默认设置。");
        } else {
          const choice = buttons.get(button);
          if (!choice) return;
          const {setting, value} = choice;
          if (button.getAttribute(optionAttr(setting)) !== value) return;
          status.textContent = "";
          apply(setting, value);
          save(setting, value);
          sync();
        }
      });
      sync();
      return dialog;
    };
    const open = () => {
      const surface = ensureDialog();
      trigger.setAttribute("aria-expanded", "true");
      if (typeof surface.showModal === "function" && !surface.open) surface.showModal();
      else surface.setAttribute("open", "");
      surface.querySelector("[aria-pressed='true']")?.focus();
    };
    const close = () => {
      trigger.setAttribute("aria-expanded", "false");
      if (!dialog) return;
      if (typeof dialog.close === "function" && dialog.open) dialog.close();
      else dialog.removeAttribute("open");
      trigger.focus();
    };
    trigger.hidden = false;
    trigger.addEventListener("click", open);
    sync();
  };

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
    document.addEventListener("click", async event => {
      const button = event.target.closest?.("[data-cjdoc-copy-link]");
      if (!button) return;
      const iconOnly = !button.textContent.trim();
      const label = button.getAttribute("aria-label") || button.textContent || "";
      const status = button.parentElement
        ? button.parentElement.querySelector("[data-cjdoc-copy-status]") : null;
      let url = button.dataset.cjdocCopyLink || "";
      try {
        url = new URL(globalThis.__CJDOC_API_ROUTE__(url), window.location.href).href;
      } catch (_) { /* keep raw */ }
      const copied = await copyText(url);
      const message = copied ? text("Link copied", "链接已复制")
        : text("Select and copy the link", "请选择并复制链接");
      flashCopyState(button, copied);
      if (iconOnly) {
        button.setAttribute("aria-label", message);
        button.setAttribute("title", message);
      } else {
        const labelNode = button.querySelector("span") || button.lastChild;
        if (labelNode) labelNode.textContent = message;
        if (button.hasAttribute("aria-label")) button.setAttribute("aria-label", message);
      }
      if (status) status.textContent = message;
      if (!copied) {
        let field = button.parentElement?.querySelector("[data-cjdoc-copy-link-fallback]");
        if (!field) {
          field = element("input", "cj-input");
          field.type = "text";
          field.readOnly = true;
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
    for (const code of all("pre > code")) {
      const panel = code.closest("[data-cjdoc-copy-panel]");
      const host = panel?.querySelector("[data-cjdoc-copy-toolbar]") || code.parentElement;
      if (!host || host.querySelector("[data-cjdoc-copy]")) continue;
      const copyLabel = panel?.dataset.cjdocCopyPanel === "output"
        ? text("Copy output", "复制输出") : text("Copy code", "复制代码");
      const button = attrs(element("button", "cj-button cj-button--quiet cj-code__copy"), {
        type: "button", "data-cjdoc-copy": "", "aria-label": copyLabel, title: copyLabel
      });
      const glyph = icon();
      glyph.append(svg("rect", {x: "8", y: "8", width: "12", height: "12", rx: "2"}),
        svg("path", {d: "M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"}));
      const idleCaption = panel ? copyLabel : text("Copy", "复制");
      const caption = element("span", "", idleCaption);
      button.append(glyph, caption);
      host.append(button);
      button.addEventListener("click", async () => {
        const original = code.getAttribute("data-cjdoc-source");
        let value = code.textContent || "";
        if (original !== null) {
          try { value = JSON.parse(original); } catch (_) { /* keep text */ }
        }
        const copied = await copyText(value);
        flashCopyState(button, copied);
        const feedback = copied ? text("Copied", "已复制") : copyLabel;
        caption.textContent = copied ? feedback : idleCaption;
        attrs(button, {"aria-label": feedback, title: feedback});
        setTimeout(() => {
          caption.textContent = idleCaption;
          attrs(button, {"aria-label": copyLabel, title: copyLabel});
        }, 1500);
      });
    }
  };

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
