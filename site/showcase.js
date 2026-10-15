"use strict";
(() => {
  const status = document.querySelector('[data-showcase-status]');
  const zh = document.documentElement.lang === 'zh-CN';
  const say = (message) => { if (status) status.textContent = message; };
  const choices = [
    ['system', zh ? '跟随系统' : 'System'],
    ['light', zh ? '浅色' : 'Light'],
    ['dark', zh ? '深色' : 'Dark'],
    ['paper', zh ? '纸色' : 'Paper'],
    ['ocean', zh ? '海洋' : 'Ocean'],
    ['forest', zh ? '森林' : 'Forest'],
    ['terminal', zh ? '终端' : 'Terminal'],
    ['violet', zh ? '紫罗兰' : 'Violet'],
  ];
  const currentTheme = () => {
    const value = document.documentElement.dataset.themeChoice;
    return choices.some(([key]) => key === value) ? value : 'system';
  };
  const applyTheme = (next) => {
    if (!choices.some(([key]) => key === next)) return;
    document.documentElement.dataset.themeChoice = next;
    document.documentElement.dataset.theme = next === 'system'
      ? (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light') : next;
    if (globalThis.__CJDOC_THEME__) globalThis.__CJDOC_THEME__.persist(next);
    else { try { localStorage.setItem('cjdoc-theme', next); } catch (_) {} }
  };
  const element = (tag, className, text) => {
    const node = document.createElement(tag);
    node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const paletteIcon = () => {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    for (const [key, value] of Object.entries({
      width: '18', height: '18', viewBox: '0 0 24 24', fill: 'none',
      stroke: 'currentColor', 'stroke-width': '1.8', 'stroke-linecap': 'round',
      'stroke-linejoin': 'round', 'aria-hidden': 'true',
    })) svg.setAttribute(key, value);
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', 'M12 3a9 9 0 1 0 0 18h1.5a2.5 2.5 0 0 0 2-4l-.7-.9a1.7 1.7 0 0 1 1.4-2.7h1.6a3.5 3.5 0 0 0 3.5-3.5A9 9 0 0 0 12 3Z');
    svg.appendChild(path);
    for (const [cx, cy] of [[13.5, 6.5], [17.8, 10.2], [7.7, 8], [6.1, 13.4]]) {
      const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      circle.setAttribute('cx', String(cx));
      circle.setAttribute('cy', String(cy));
      circle.setAttribute('r', '1');
      svg.appendChild(circle);
    }
    return svg;
  };
  const setupThemePicker = (trigger) => {
    const wrapper = element('span', 'showcase-theme-control');
    trigger.parentNode.insertBefore(wrapper, trigger);
    wrapper.appendChild(trigger);
    trigger.className = 'showcase-theme-trigger';
    trigger.textContent = '';
    const label = element('span', 'showcase-theme-label');
    trigger.append(paletteIcon(), label, element('span', 'showcase-theme-chevron', '⌄'));
    trigger.setAttribute('aria-controls', 'showcase-theme-menu');
    trigger.setAttribute('aria-expanded', 'false');

    const backdrop = element('button', 'showcase-theme-backdrop');
    backdrop.type = 'button';
    backdrop.hidden = true;
    backdrop.tabIndex = -1;
    backdrop.setAttribute('aria-label', zh ? '关闭主题选择器' : 'Close theme selector');
    const menu = element('div', 'showcase-theme-menu');
    menu.id = 'showcase-theme-menu';
    menu.hidden = true;
    menu.setAttribute('role', 'group');
    menu.setAttribute('aria-label', zh ? '选择主题' : 'Choose theme');
    const heading = element('div', 'showcase-theme-heading');
    heading.appendChild(element('strong', '', zh ? '外观主题' : 'Appearance'));
    const close = element('button', 'showcase-theme-close', '×');
    close.type = 'button';
    close.setAttribute('aria-label', zh ? '关闭' : 'Close');
    heading.appendChild(close);
    menu.appendChild(heading);

    const buttons = [];
    choices.forEach(([key, name], index) => {
      if (index === 0 || index === 3) {
        menu.appendChild(element('p', index === 3 ? 'showcase-theme-group preset' : 'showcase-theme-group',
          index === 3 ? (zh ? '配色预设' : 'Color presets') : (zh ? '基础模式' : 'Basic modes')));
      }
      const option = element('button', 'showcase-theme-option', name);
      option.type = 'button';
      option.dataset.showcaseThemeValue = key;
      option.setAttribute('aria-pressed', 'false');
      menu.appendChild(option);
      buttons.push(option);
    });
    menu.appendChild(element('p', 'showcase-theme-help',
      zh ? '跟随系统会采用设备的外观设置。' : 'System follows your device appearance.'));
    wrapper.append(backdrop, menu);

    const sync = () => {
      const active = currentTheme();
      const entry = choices.find(([key]) => key === active);
      label.textContent = (zh ? '主题：' : 'Theme: ') + entry[1];
      trigger.setAttribute('aria-label', (zh ? '选择主题：' : 'Select theme: ') + entry[1]);
      buttons.forEach((button) => button.setAttribute('aria-pressed',
        button.dataset.showcaseThemeValue === active ? 'true' : 'false'));
    };
    const isMobile = () => Boolean(window.matchMedia &&
      window.matchMedia('(max-width: 640px)').matches);
    let modalActive = false;
    let inertNodes = [];
    const setModal = (active) => {
      if (modalActive === active) return;
      modalActive = active;
      if (active) {
        menu.setAttribute('role', 'dialog');
        menu.setAttribute('aria-modal', 'true');
        const isolate = (node) => {
          if (node === menu || node === backdrop) return;
          if (node.contains(menu) || node.contains(backdrop)) {
            for (const child of node.children) isolate(child);
          } else {
            inertNodes.push([node, node.inert]);
            node.inert = true;
          }
        };
        if (document.body) for (const child of document.body.children) isolate(child);
      } else {
        for (const [node, wasInert] of inertNodes) node.inert = wasInert;
        inertNodes = [];
        menu.setAttribute('role', 'group');
        menu.removeAttribute('aria-modal');
      }
    };
    const trapFocus = (event) => {
      if (!modalActive || menu.hidden || event.key !== 'Tab') return;
      const items = [...menu.querySelectorAll('button:not([disabled]), a[href], [tabindex]')]
        .filter(node => !node.hidden && node.tabIndex >= 0 && node.getClientRects().length > 0);
      const first = items[0], last = items[items.length - 1];
      if (!first) { event.preventDefault(); menu.focus(); return; }
      if (event.shiftKey && (document.activeElement === first ||
        !menu.contains(document.activeElement))) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && (document.activeElement === last ||
        !menu.contains(document.activeElement))) {
        event.preventDefault();
        first.focus();
      }
    };
    const dismiss = (focus = false) => {
      if (menu.hidden) return;
      menu.hidden = true;
      backdrop.hidden = true;
      setModal(false);
      document.documentElement.classList.remove('showcase-theme-open');
      trigger.setAttribute('aria-expanded', 'false');
      if (focus) trigger.focus();
    };
    trigger.addEventListener('click', () => {
      const open = menu.hidden;
      menu.hidden = !open;
      backdrop.hidden = !open;
      document.documentElement.classList.toggle('showcase-theme-open', open);
      setModal(open && isMobile());
      trigger.setAttribute('aria-expanded', open ? 'true' : 'false');
      if (open) buttons.find((button) => button.getAttribute('aria-pressed') === 'true').focus();
    });
    buttons.forEach((button) => button.addEventListener('click', () => {
      applyTheme(button.dataset.showcaseThemeValue);
      sync();
      dismiss(true);
    }));
    backdrop.addEventListener('click', () => dismiss(true));
    close.addEventListener('click', () => dismiss(true));
    document.addEventListener('click', (event) => {
      if (!menu.hidden && !wrapper.contains(event.target)) dismiss();
    });
    document.addEventListener('keydown', (event) => {
      trapFocus(event);
      if (!menu.hidden && event.key === 'Escape') {
        event.stopPropagation();
        dismiss(true);
      }
    }, true);
    window.addEventListener?.('resize', () => {
      if (!menu.hidden) setModal(isMobile());
    });
    sync();
  };
  document.querySelectorAll('[data-showcase-theme]').forEach(setupThemePicker);

  document.querySelectorAll('[data-showcase-copy]').forEach(button => button.addEventListener('click', async () => {
    const source = document.getElementById(button.dataset.showcaseCopy);
    if (!source) return;
    const text = source.textContent;
    let copied = false;
    try { if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(text); copied = true; } } catch (_) {}
    if (!copied) {
      const field = document.createElement('textarea'); field.value = text;
      field.style.position = 'fixed'; field.style.left = '-10000px'; document.body.appendChild(field); field.select();
      try { copied = document.execCommand('copy'); } catch (_) {} finally { field.remove(); }
    }
    button.dataset.copyResult = copied ? 'copied' : 'unavailable';
    say(copied ? (zh ? '已复制' : 'Copied') : (zh ? '剪贴板不可用，请手动选择代码' : 'Clipboard unavailable; select the code manually'));
  }));
  if (location.protocol === 'file:') document.querySelectorAll('[data-offline-download]').forEach(link => {
    link.removeAttribute('href'); link.setAttribute('aria-disabled', 'true');
    link.textContent = zh ? '当前已是解压后的离线目录' : 'Already viewing the extracted offline site';
  });
})();
