"use strict";
(() => {
  const status = document.querySelector('[data-showcase-status]');
  const say = (message) => { if (status) status.textContent = message; };
  const theme = document.querySelector('[data-showcase-theme]');
  try { const saved = localStorage.getItem('cjdoc-showcase-theme'); if (saved === 'dark' || saved === 'light') document.documentElement.dataset.theme = saved; } catch (_) {}
  if (theme) theme.addEventListener('click', () => {
    const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem('cjdoc-showcase-theme', next); } catch (_) {}
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
    say(copied ? 'Copied / 已复制' : 'Clipboard unavailable; select the code manually / 请手动选择代码');
  }));
  if (location.protocol === 'file:') document.querySelectorAll('[data-offline-download]').forEach(link => {
    link.removeAttribute('href'); link.setAttribute('aria-disabled', 'true');
    link.textContent = 'Already viewing the extracted offline site / 当前已是解压后的离线目录';
  });
})();
