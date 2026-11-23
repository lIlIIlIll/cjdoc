protected package cjdoc.render.browser

// Reader preferences, example disclosure and admonition grouping.
internal let HTML_READING_SETTINGS_SCRIPT = """
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

"""
