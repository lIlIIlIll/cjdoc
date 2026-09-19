(() => {
  const root = document.documentElement;
  const themeButton = document.querySelector('[data-theme-toggle]');
  const copyButton = document.querySelector('[data-copy]');
  const copyStatus = document.querySelector('[data-copy-status]');

  const applyTheme = (theme) => {
    root.dataset.theme = theme;
    if (themeButton) {
      themeButton.setAttribute('aria-label', `Switch to ${theme === 'dark' ? 'light' : 'dark'} theme`);
      themeButton.title = `Switch to ${theme === 'dark' ? 'light' : 'dark'} theme`;
    }
  };

  const storedTheme = (() => {
    try { return localStorage.getItem('cjdoc-theme'); } catch (_) { return null; }
  })();
  applyTheme(storedTheme === 'light' ? 'light' : 'dark');

  themeButton?.addEventListener('click', () => {
    const next = root.dataset.theme === 'dark' ? 'light' : 'dark';
    applyTheme(next);
    try { localStorage.setItem('cjdoc-theme', next); } catch (_) { /* file:// storage can be unavailable */ }
  });

  copyButton?.addEventListener('click', async () => {
    const value = copyButton.dataset.copy;
    try {
      await navigator.clipboard.writeText(value);
      copyButton.textContent = 'copied';
      if (copyStatus) copyStatus.textContent = 'Command copied to the clipboard.';
    } catch (_) {
      if (copyStatus) copyStatus.textContent = value;
    }
    window.setTimeout(() => { copyButton.textContent = 'copy'; }, 1800);
  });
})();
