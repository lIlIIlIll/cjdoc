package cjdoc.render


internal let HTML_THEME_BOOTSTRAP_SCRIPT = """
(() => {
  const themes = new Set(["system", "light", "dark", "paper", "ocean", "forest", "terminal", "violet"]);
  const isKnownTheme = (value) => themes.has(value);
  const readQueryTheme = () => {
    try {
      const value = new URLSearchParams(window.location.search).get("theme");
      return isKnownTheme(value) ? value : null;
    } catch (_) { return null; }
  };
  const readStoredTheme = () => {
    try { return localStorage.getItem("cjdoc-theme"); } catch (_) { return null; }
  };
  const queryTheme = readQueryTheme();
  const storedTheme = readStoredTheme();
  const initialTheme = queryTheme || (isKnownTheme(storedTheme) ? storedTheme : "system");
  if (initialTheme === "system") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = initialTheme;
  const state = {navigationTheme: queryTheme, linkListenerInstalled: false};
  const installLinkPropagation = () => {
    if (!state.navigationTheme || state.linkListenerInstalled) return;
    state.linkListenerInstalled = true;
    document.addEventListener("click", (event) => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
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

internal let HTML_SEARCH_SCRIPT = """
(() => {
  const input = document.querySelector("[data-cjdoc-search]");
  const results = document.querySelector("[data-cjdoc-results]");
  if (!input || !results) return;
  const isChinese = (document.documentElement.lang || "").toLocaleLowerCase().startsWith("zh");
  const copyLabels = isChinese
    ? {copy: "复制代码", copied: "已复制"}
    : {copy: "Copy code", copied: "Copied"};
  const themeSwitchLabel = (next) => {
    if (!isChinese) return "Switch to " + next + " theme";
    return "切换到" + (next === "light" ? "浅色" : "深色") + "主题";
  };
  const root = input.dataset.root || "";
  const kindFilter = document.querySelector("[data-cjdoc-kind]");
  const packageFilter = document.querySelector("[data-cjdoc-package]");
  let entries = [];
  let visible = [];
  let selected = -1;
  const ambiguousLabels = new Set();
  const displayKey = (entry) => JSON.stringify([entry.packageName, entry.qualifiedName]);
  const rank = (entry, query) => {
    const name = entry.name.toLocaleLowerCase();
    const qualified = entry.qualifiedName.toLocaleLowerCase();
    if (name === query) return 0;
    if (qualified === query) return 1;
    if (name.startsWith(query)) return 2;
    if (qualified.startsWith(query)) return 3;
    const haystack = (entry.qualifiedName + " " + entry.kind + " " + entry.packageName + " " + entry.summary).toLocaleLowerCase();
    return query.split(/\\s+/).filter(Boolean).every((token) => haystack.includes(token)) ? 4 : -1;
  };
  const select = (next) => {
    if (!visible.length) return;
    selected = (next + visible.length) % visible.length;
    for (let i = 0; i < results.children.length; i += 1) {
      results.children[i].setAttribute("aria-selected", i === selected ? "true" : "false");
    }
    const active = results.children[selected];
    input.setAttribute("aria-activedescendant", active.id);
    active.scrollIntoView({block: "nearest"});
  };
  const render = () => {
    results.replaceChildren();
    visible = [];
    selected = -1;
    input.removeAttribute("aria-activedescendant");
    const query = input.value.trim().toLocaleLowerCase();
    if (!query) { input.setAttribute("aria-expanded", "false"); return; }
    const selectedKind = kindFilter ? kindFilter.value : "";
    const selectedPackage = packageFilter ? packageFilter.value : "";
    visible = entries.map((entry) => ({entry, rank: rank(entry, query)}))
      .filter((item) => item.rank >= 0 && (!selectedKind || item.entry.kind === selectedKind) &&
        (!selectedPackage || item.entry.packageName === selectedPackage))
      .sort((left, right) => left.rank - right.rank ||
        left.entry.qualifiedName.localeCompare(right.entry.qualifiedName) || left.entry.id.localeCompare(right.entry.id))
      .slice(0, 20).map((item) => item.entry);
    for (const entry of visible) {
      const item = document.createElement("li");
      const link = document.createElement("a");
      const name = document.createElement("span");
      const kind = document.createElement("span");
      item.id = "cjdoc-search-result-" + results.children.length;
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", "false");
      link.href = root + entry.href;
      name.textContent = entry.qualifiedName;
      kind.className = "search-kind";
      kind.textContent = " — " + entry.kind +
        (ambiguousLabels.has(displayKey(entry)) ? " · " + entry.id : "");
      link.append(name, kind);
      item.append(link);
      results.append(item);
    }
    input.setAttribute("aria-expanded", visible.length ? "true" : "false");
  };
  const addOptions = (selectElement, values) => {
    if (!selectElement) return;
    for (const value of [...new Set(values)].sort((a, b) => a.localeCompare(b))) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value;
      selectElement.append(option);
    }
  };
  const index = globalThis.__CJDOC_SEARCH_INDEX__;
  entries = index && index.schemaVersion === "cjdoc.search-index/4" && Array.isArray(index.entries)
    ? index.entries : [];
  const firstIdsByLabel = new Map();
  for (const entry of entries) {
    const key = displayKey(entry);
    if (firstIdsByLabel.has(key) && firstIdsByLabel.get(key) !== entry.id) ambiguousLabels.add(key);
    else firstIdsByLabel.set(key, entry.id);
  }
  addOptions(kindFilter, entries.map((entry) => entry.kind));
  addOptions(packageFilter, entries.map((entry) => entry.packageName));
  render();
  input.addEventListener("input", render);
  if (kindFilter) kindFilter.addEventListener("change", render);
  if (packageFilter) packageFilter.addEventListener("change", render);
  input.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") { event.preventDefault(); select(selected + 1); }
    else if (event.key === "ArrowUp") { event.preventDefault(); select(selected < 0 ? visible.length - 1 : selected - 1); }
    else if (event.key === "Enter" && selected >= 0) { event.preventDefault(); results.children[selected].querySelector("a").click(); }
    else if (event.key === "Escape") { input.value = ""; render(); }
  });
  document.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLocaleLowerCase() === "k") {
      event.preventDefault(); input.focus();
    }
  });
  const themeToggle = document.querySelector("[data-cjdoc-theme-toggle]");
  const themeOptions = [
    ["system", "System", "跟随系统"],
    ["light", "Light", "浅色"],
    ["dark", "Dark", "深色"],
    ["paper", "Paper", "纸张"],
    ["ocean", "Ocean", "深海"],
    ["forest", "Forest", "松林"],
    ["terminal", "Terminal", "终端"],
    ["violet", "Violet", "紫墨"]
  ];
  const themeValues = new Set(themeOptions.slice(1).map((option) => option[0]));
  const darkThemes = new Set(["dark", "ocean", "terminal"]);
  const themePersistence = globalThis.__CJDOC_THEME__;
  const isKnownTheme = (value) => themeValues.has(value);
  const createThemePicker = () => {
    if (!themeToggle) return null;
    const picker = document.createElement("label");
    const pickerText = document.createElement("span");
    const select = document.createElement("select");
    const isChinese = (document.documentElement.lang || "").toLocaleLowerCase().startsWith("zh");
    picker.className = "theme-picker";
    pickerText.className = "sr-only";
    pickerText.textContent = isChinese ? "主题" : "Theme";
    select.setAttribute("aria-label", pickerText.textContent);
    select.dataset.cjdocThemeSelect = "";
    for (const optionData of themeOptions) {
      const option = document.createElement("option");
      option.value = optionData[0];
      option.textContent = isChinese ? optionData[2] : optionData[1];
      select.append(option);
    }
    picker.append(pickerText, select);
    themeToggle.before(picker);
    return select;
  };
  const themeSelect = createThemePicker();
  const readTheme = () => {
    const explicit = document.documentElement.dataset.theme;
    if (isKnownTheme(explicit)) return explicit;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "dark" : "light";
  };
  const syncThemeControls = () => {
    const explicit = document.documentElement.dataset.theme;
    if (themeSelect) themeSelect.value = isKnownTheme(explicit) ? explicit : "system";
    if (!themeToggle) return;
    const current = readTheme();
    const isDark = darkThemes.has(current);
    const next = isDark ? "light" : "dark";
    themeToggle.dataset.mode = isDark ? "dark" : "light";
    themeToggle.setAttribute("aria-pressed", isDark ? "true" : "false");
    themeToggle.setAttribute("aria-label", themeSwitchLabel(next));
    themeToggle.title = themeSwitchLabel(next);
  };
  const setTheme = (next) => {
    if (next === "system") delete document.documentElement.dataset.theme;
    else if (isKnownTheme(next)) document.documentElement.dataset.theme = next;
    else return;
    if (themePersistence && typeof themePersistence.persist === "function") themePersistence.persist(next);
    else try { localStorage.setItem("cjdoc-theme", next); } catch (_) { /* optional */ }
    syncThemeControls();
  };
  if (themeToggle || themeSelect) {
    if (!themePersistence) {
      try {
        const storedTheme = localStorage.getItem("cjdoc-theme");
        if (storedTheme === "system") delete document.documentElement.dataset.theme;
        else if (isKnownTheme(storedTheme)) document.documentElement.dataset.theme = storedTheme;
      } catch (_) { /* file:// storage can be unavailable */ }
    }
    syncThemeControls();
    if (themeToggle) {
      themeToggle.addEventListener("click", () => {
        setTheme(darkThemes.has(readTheme()) ? "light" : "dark");
      });
    }
    if (themeSelect) themeSelect.addEventListener("change", () => setTheme(themeSelect.value));
  }
  const toc = document.querySelector("[data-cjdoc-toc]");
  const content = document.querySelector("[data-cjdoc-content]");
  if (toc && content) {
    const tocList = toc.querySelector("ol");
    const allHeadings = [...content.querySelectorAll("h1, h2, h3, h4")];
    const semanticHeadings = allHeadings.filter((heading) => {
      const role = heading.dataset.cjdocTocRole;
      return role === "api-root" || role === "api" || role === "member";
    });
    const semanticMode = semanticHeadings.length > 0;
    const headings = semanticMode
      ? semanticHeadings : allHeadings.filter((heading) => heading.tagName === "H2" || heading.tagName === "H3");
    const usedIds = new Set();
    const slug = (value, index) => {
      const normalized = value.toLocaleLowerCase().replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "");
      return normalized || "section-" + index;
    };
    const ensureHeadingId = (heading, index) => {
      let id = heading.id || slug(heading.textContent.trim(), index);
      const base = id;
      let suffix = 2;
      while (usedIds.has(id)) { id = base + "-" + suffix; suffix += 1; }
      heading.id = id;
      usedIds.add(id);
    };
    const headingLabel = (heading) => {
      const explicit = heading.dataset.cjdocTocLabel;
      return (explicit || heading.textContent).trim().replace(/\\s+/g, " ");
    };
    const createLink = (heading, className) => {
      const link = document.createElement("a");
      const sourceLink = heading.querySelector("a[href]");
      const target = sourceLink ? sourceLink.getAttribute("href") : null;
      link.className = "toc-link " + className;
      link.setAttribute("href", target || "#" + heading.id);
      link.dataset.tocTarget = heading.id;
      link.textContent = headingLabel(heading);
      return link;
    };
    const appendFlatItem = (heading, index) => {
      const item = document.createElement("li");
      item.dataset.depth = heading.tagName === "H3" ? "3" : "2";
      item.append(createLink(heading, "toc-flat-link"));
      tocList.append(item);
    };
    const isChinese = (document.documentElement.lang || "").toLocaleLowerCase().startsWith("zh");
    const createToggle = (labelText, children, initiallyExpanded) => {
      const button = document.createElement("button");
      const icon = document.createElement("span");
      const setExpanded = (expanded) => {
        button.setAttribute("aria-expanded", expanded ? "true" : "false");
        button.setAttribute("aria-label", (expanded
          ? (isChinese ? "收起 " : "Collapse ") : (isChinese ? "展开 " : "Expand ")) + labelText);
        icon.textContent = expanded ? "▾" : "▸";
        children.hidden = !expanded;
      };
      button.type = "button";
      button.className = "toc-toggle";
      button.setAttribute("aria-controls", children.id);
      icon.className = "toc-toggle-icon";
      icon.setAttribute("aria-hidden", "true");
      button.append(icon);
      button.addEventListener("click", () => {
        setExpanded(button.getAttribute("aria-expanded") !== "true");
      });
      setExpanded(initiallyExpanded);
      return {button, setExpanded};
    };
    const parentByLink = new Map();
    const apiNodes = [];
    const createApiNode = (heading, index) => {
      const item = document.createElement("li");
      const row = document.createElement("div");
      const link = createLink(heading, "toc-api-link");
      item.className = "toc-api-item";
      row.className = "toc-api-row";
      row.append(link);
      item.append(row);
      const node = {heading, item, row, link, children: null, setExpanded: null, index};
      apiNodes.push(node);
      return node;
    };
    const appendMember = (parent, heading) => {
      if (!parent.children) {
        const children = document.createElement("ol");
        children.className = "toc-children";
        children.id = "toc-children-" + parent.index;
        const toggle = createToggle(headingLabel(parent.heading), children,
          parent.heading.dataset.cjdocTocRole === "api-root");
        parent.children = children;
        parent.setExpanded = toggle.setExpanded;
        parent.row.insertBefore(toggle.button, parent.row.firstChild);
        parent.item.append(children);
      }
      const item = document.createElement("li");
      const link = createLink(heading, "toc-member-link");
      item.className = "toc-member-item";
      item.append(link);
      parent.children.append(item);
      parentByLink.set(link, parent);
    };
    for (let index = 0; index < headings.length; index += 1) {
      ensureHeadingId(headings[index], index);
    }
    tocList.replaceChildren();
    if (semanticMode) {
      let currentApi = null;
      for (const heading of headings) {
        const role = heading.dataset.cjdocTocRole;
        if (role === "api-root" || role === "api") {
          currentApi = createApiNode(heading, apiNodes.length);
          tocList.append(currentApi.item);
        } else if (role === "member" && currentApi) {
          appendMember(currentApi, heading);
        }
      }
    } else {
      for (let index = 0; index < headings.length; index += 1) {
        appendFlatItem(headings[index], index);
      }
    }
    toc.hidden = headings.length === 0;
    if (headings.length && "IntersectionObserver" in window) {
      const links = [...tocList.querySelectorAll("a")];
      const byId = new Map(links.map((link) => [link.dataset.tocTarget, link]));
      const setActive = (targetId) => {
        for (const link of links) {
          link.classList.remove("is-active", "is-parent-active");
        }
        const active = byId.get(targetId);
        if (!active) return;
        active.classList.add("is-active");
        const parent = parentByLink.get(active);
        if (parent) {
          parent.link.classList.add("is-parent-active");
          parent.setExpanded(true);
        }
      };
      for (const link of links) {
        link.addEventListener("click", () => {
          const parent = parentByLink.get(link);
          if (parent) parent.setExpanded(true);
          setActive(link.dataset.tocTarget);
        });
      }
      const observer = new IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          setActive(entry.target.id);
        }
      }, {rootMargin: "-18% 0px -68% 0px", threshold: 0});
      for (const heading of headings) observer.observe(heading);
      setActive(headings[0].id);
    } else if (headings.length) {
      const firstLink = tocList.querySelector("a");
      if (firstLink) firstLink.classList.add("is-active");
    }
  }
  const copyText = async (value) => {
    if (navigator.clipboard && window.isSecureContext) {
      try { await navigator.clipboard.writeText(value); return true; } catch (_) { /* fallback */ }
    }
    const area = document.createElement("textarea");
    area.value = value; area.setAttribute("readonly", "");
    area.style.position = "fixed"; area.style.opacity = "0";
    document.body.append(area); area.select();
    let copied = false;
    try { copied = document.execCommand("copy"); } catch (_) { copied = false; }
    area.remove();
    return copied;
  };
  for (const code of document.querySelectorAll("pre > code")) {
    const pre = code.parentElement;
    if (pre.querySelector("[data-cjdoc-copy]")) continue;
    const button = document.createElement("button");
    button.type = "button"; button.className = "code-copy";
    button.setAttribute("aria-label", copyLabels.copy);
    button.title = copyLabels.copy;
    button.textContent = "⧉";
    pre.append(button);
    button.addEventListener("click", async () => {
      const copied = await copyText(code.textContent || "");
      button.dataset.copied = copied ? "true" : "false";
      button.setAttribute("aria-label", copied ? copyLabels.copied : copyLabels.copy);
      button.title = copied ? copyLabels.copied : copyLabels.copy;
      if (copied) window.setTimeout(() => {
        button.dataset.copied = "false";
        button.setAttribute("aria-label", copyLabels.copy);
        button.title = copyLabels.copy;
      }, 1400);
    });
  }
})();
"""
