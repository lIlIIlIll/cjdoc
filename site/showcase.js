"use strict";
(() => {
  const status = document.querySelector('[data-showcase-status]');
  const zh = document.documentElement.lang === 'zh-CN';
  const say = (message) => { if (status) status.textContent = message; };
  const theme = document.querySelector('[data-showcase-theme]');
  if (theme) theme.addEventListener('click', () => {
    const next = ['dark', 'ocean', 'terminal'].includes(document.documentElement.dataset.theme) ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    if (globalThis.__CJDOC_THEME__) globalThis.__CJDOC_THEME__.persist(next);
    else { try { localStorage.setItem('cjdoc-theme', next); } catch (_) {} }
  });
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
