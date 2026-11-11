import { test, expect, chromium } from '@playwright/test';
import { createServer } from 'node:http';
import { access, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const fixtureRoot = path.resolve(process.env.CJDOC_ADMONITION_FIXTURE || '');
if (!process.env.CJDOC_ADMONITION_FIXTURE) throw new Error('CJDOC_ADMONITION_FIXTURE is required');
const locales = [
  { id: 'en', note: 'Note', warning: 'Warning', danger: 'Danger' },
  { id: 'zh-CN', note: '注意', warning: '警告', danger: '危险' },
];
const themes = ['light', 'dark', 'paper', 'ocean', 'forest', 'terminal', 'violet', 'system'];
let server, origin;

async function isFile(file) {
  try { await access(file); return true; } catch { return false; }
}
async function siteRoot(locale) {
  const candidates = [
    path.join(fixtureRoot, locale, 'html'), path.join(fixtureRoot, locale),
    path.join(fixtureRoot, 'html', locale), fixtureRoot,
  ];
  for (const candidate of candidates) {
    if (await isFile(path.join(candidate, 'index.html')) &&
        await isFile(path.join(candidate, 'search-index.json'))) return candidate;
  }
  throw new Error(`generated ${locale} HTML site is missing`);
}
async function safePagePath(root, href) {
  const file = path.resolve(root, href.split(/[?#]/, 1)[0]);
  if (!file.startsWith(root + path.sep)) throw new Error('search route escaped the site root');
  if (!await isFile(file)) throw new Error('search route did not resolve to an HTML file');
  return file;
}
async function samplePages(locale) {
  const root = await siteRoot(locale);
  const index = JSON.parse(await readFile(path.join(root, 'search-index.json'), 'utf8'));
  const member = index.entries.find(entry => entry.name === 'commit' && entry.kind === 'function');
  if (!member?.ownerId) throw new Error('fixture commit member is missing its owner identity');
  const owner = index.entries.find(entry => entry.canonicalId === member.ownerId);
  if (!owner) throw new Error('fixture Cache owner is missing from the search index');
  const guide = path.join(root, 'concepts', 'guides', 'admonitions.html');
  if (!await isFile(guide)) throw new Error('generated admonition guide is missing');
  return { root, owner: await safePagePath(root, owner.href), guide };
}
function urlFor(pages, file, locale, transport) {
  if (transport === 'file') return pathToFileURL(file).href;
  const relative = path.relative(pages.root, file).split(path.sep).map(encodeURIComponent).join('/');
  return `${origin}/${transport === 'subpath' ? 'docs/' : ''}${locale}/${relative}`;
}
function observeErrors(page) {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  return errors;
}
async function noOverflow(page) {
  const dimensions = await page.evaluate(() => ({
    viewport: document.documentElement.clientWidth, document: document.documentElement.scrollWidth,
  }));
  expect(dimensions.document).toBeLessThanOrEqual(dimensions.viewport + 1);
}
async function memberDetails(page, locale) {
  const details = page.locator('details.cj-member[data-member-name="commit"]').first();
  const summary = details.locator('summary');
  const badges = summary.locator('.cj-risk');
  await expect(badges).toHaveText([locale.danger, locale.warning]);
  expect(await badges.evaluateAll(elements => elements.map(element => element.dataset.admonitionLevel)))
    .toEqual(['danger', 'warning']);
  await expect(summary.locator('.cj-risk[data-admonition-level="note"]')).toHaveCount(0);
  for (const icon of await badges.locator('svg').all()) await expect(icon).toHaveAttribute('aria-hidden', 'true');
  expect(await badges.evaluateAll(elements => elements.every(element =>
    element.tabIndex < 0 && element.scrollWidth <= element.clientWidth + 1))).toBe(true);
  return { details, summary };
}
async function staticAlerts(page) {
  await expect(page.locator('aside.cj-admonition[role="alert"], aside.cj-admonition[aria-live]')).toHaveCount(0);
  await expect(page.locator('aside.cj-admonition svg:not([aria-hidden="true"])')).toHaveCount(0);
}
async function guideContract(page, locale, checkColors = true) {
  const asides = page.locator('aside.cj-admonition');
  await expect(asides).toHaveCount(4);
  await expect(page.locator('aside.cj-admonition[data-admonition-level="note"]')).toHaveCount(1);
  await expect(page.locator('aside.cj-admonition[data-admonition-level="warning"]')).toHaveCount(2);
  await expect(page.locator('aside.cj-admonition[data-admonition-level="danger"]')).toHaveCount(1);
  for (const [level, label] of [['note', locale.note], ['warning', locale.warning], ['danger', locale.danger]]) {
    for (const aside of await page.locator(`aside.cj-admonition[data-admonition-level="${level}"]`).all()) {
      await expect(aside).toBeVisible();
      await expect(aside).toHaveAttribute('aria-label', label);
      await expect(aside.locator('.cj-admonition__icon svg')).toBeVisible();
    }
  }
  await expect(page.locator('img[src="x"]')).toHaveCount(0);
  const text = (await page.locator('body').innerText()).replace(/\s+/g, ' ');
  for (const literal of ['<img src=x onerror=alert(1)>', '[!DANGER]', '[!TIP]',
    '[!NOTE] Inline marker text', '[!WARNING] Nested alert-like text']) expect(text).toContain(literal);
  if (checkColors) {
    const colors = await asides.evaluateAll(elements => elements.map(element => getComputedStyle(element).borderLeftColor));
    expect(new Set(colors).size).toBe(3);
  }
  await staticAlerts(page);
  await noOverflow(page);
}

test.beforeAll(async () => {
  const roots = new Map(await Promise.all(locales.map(async locale => [locale.id, await siteRoot(locale.id)])));
  server = createServer(async (request, response) => {
    try {
      let pathname = decodeURIComponent(new URL(request.url, 'http://example.test').pathname);
      if (pathname.endsWith('/favicon.ico')) return response.writeHead(204).end();
      if (pathname.startsWith('/docs/')) pathname = pathname.slice(5);
      const segments = pathname.split('/').filter(Boolean);
      const root = roots.get(segments.shift());
      if (!root) throw new Error('unknown locale');
      const file = path.resolve(root, segments.join('/'));
      if (!file.startsWith(root + path.sep)) throw new Error('unsafe resource path');
      const type = { '.html': 'text/html; charset=utf-8', '.css': 'text/css',
        '.js': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml' }[path.extname(file)];
      response.writeHead(200, { 'Content-Type': type || 'application/octet-stream' });
      response.end(await readFile(file));
    } catch { response.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
});
test.afterAll(async () => { if (server) await new Promise(resolve => server.close(resolve)); });

for (const locale of locales) {
  for (const width of [390, 960, 1440]) {
    for (const theme of themes) {
      for (const colorScheme of theme === 'system' ? ['light', 'dark'] : ['light']) {
        test(`${locale.id} ${width} ${theme}/${colorScheme}: full static bodies and compact risks`, async ({ browser }, info) => {
          const pages = await samplePages(locale.id);
          const context = await browser.newContext({ viewport: { width, height: 900 }, colorScheme, reducedMotion: 'reduce' });
          try {
            const page = await context.newPage();
            const errors = observeErrors(page);
            await page.goto(pathToFileURL(pages.owner).href);
            await expect(page.locator('html')).toHaveAttribute('lang', locale.id);
            const applyTheme = () => page.evaluate(theme => {
              if (theme === 'system') document.documentElement.removeAttribute('data-theme');
              else document.documentElement.dataset.theme = theme;
            }, theme);
            await applyTheme();
            const { details, summary } = await memberDetails(page, locale);
            await expect(details).not.toHaveAttribute('open', '');
            await noOverflow(page);
            await page.screenshot({ path: info.outputPath('owner-collapsed.png'), fullPage: true });
            await summary.focus();
            await page.keyboard.press('Enter');
            await expect(details).toHaveAttribute('open', '');
            await expect(summary).toBeFocused();
            await expect(details).toContainText('AdmonitionSearchSentinel');
            await expect(details.locator('aside.cj-admonition[data-admonition-level="warning"]')).toBeVisible();
            await expect(details.locator('aside.cj-admonition[data-admonition-level="danger"]')).toBeVisible();
            await staticAlerts(page);
            await noOverflow(page);
            await page.screenshot({ path: info.outputPath('owner-expanded.png'), fullPage: true });
            await page.goto(pathToFileURL(pages.guide).href);
            await applyTheme();
            await guideContract(page, locale);
            await page.screenshot({ path: info.outputPath('guide.png'), fullPage: true });
            expect(errors).toEqual([]);
          } finally { await context.close(); }
        });
      }
    }
  }
  for (const transport of ['file', 'root', 'subpath']) {
    test(`${locale.id} ${transport}: keyboard, touch, reduced motion and safe static content`, async ({ browser }) => {
      const pages = await samplePages(locale.id);
      const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, reducedMotion: 'reduce' });
      try {
        const page = await context.newPage();
        const errors = observeErrors(page);
        await page.goto(urlFor(pages, pages.owner, locale.id, transport));
        const { details, summary } = await memberDetails(page, locale);
        await summary.focus();
        await page.keyboard.press('Enter');
        await expect(summary).toBeFocused();
        await expect(details).toHaveAttribute('open', '');
        await page.keyboard.press('Space');
        await expect(details).not.toHaveAttribute('open', '');
        await summary.tap();
        await expect(details.locator('aside.cj-admonition[data-admonition-level="danger"]')).toBeVisible();
        expect(await page.evaluate(() => matchMedia('(prefers-reduced-motion: reduce)').matches)).toBe(true);
        await noOverflow(page);
        await page.goto(urlFor(pages, pages.guide, locale.id, transport));
        await guideContract(page, locale);
        expect(errors).toEqual([]);
      } finally { await context.close(); }
    });
  }
  test(`${locale.id}: no-JS and print preserve the full authored risk body`, async ({ browser }, info) => {
    const pages = await samplePages(locale.id);
    const context = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 390, height: 844 } });
    try {
      const page = await context.newPage();
      await page.goto(pathToFileURL(pages.owner).href);
      const note = page.locator('aside.cj-admonition[data-admonition-level="note"]').first();
      await expect(note).toBeVisible();
      await expect(note).toHaveAttribute('aria-label', locale.note);
      const { details, summary } = await memberDetails(page, locale);
      for (const aside of await details.locator('aside.cj-admonition').all()) await expect(aside).toBeHidden();
      await summary.focus();
      await page.keyboard.press('Enter');
      await expect(details.locator('aside.cj-admonition[data-admonition-level="danger"]')).toBeVisible();
      await page.keyboard.press('Space');
      await expect(details).not.toHaveAttribute('open', '');
      await page.emulateMedia({ media: 'print' });
      await expect(details.locator('aside.cj-admonition[data-admonition-level="danger"]')).toBeVisible();
      await expect(details).toContainText('AdmonitionSearchSentinel');
      await staticAlerts(page);
      await page.screenshot({ path: info.outputPath('no-js-print-owner.png'), fullPage: true });
      await page.goto(pathToFileURL(pages.guide).href);
      await guideContract(page, locale, false);
      await expect(page.locator('aside.cj-admonition[data-admonition-level="danger"]'))
        .toContainText('Never publish a partially captured result.');
    } finally { await context.close(); }
  });
}

test('native 200% browser zoom keeps risk labels, prose and native disclosure usable', async ({}, info) => {
  const extension = info.outputPath('zoom-extension');
  await mkdir(extension, { recursive: true });
  await writeFile(path.join(extension, 'manifest.json'), JSON.stringify({
    manifest_version: 3, name: 'Native zoom acceptance', version: '1.0',
    permissions: ['tabs'], background: { service_worker: 'worker.js' },
  }));
  await writeFile(path.join(extension, 'worker.js'), 'chrome.runtime.onInstalled.addListener(() => {});');
  const profile = info.outputPath('zoom-profile');
  const context = await chromium.launchPersistentContext(profile, {
    channel: 'chromium', headless: true, viewport: null,
    args: ['--window-size=1440,900', `--disable-extensions-except=${extension}`, `--load-extension=${extension}`],
  });
  try {
    const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
    for (const locale of locales) {
      const pages = await samplePages(locale.id);
      const page = await context.newPage();
      await page.goto(urlFor(pages, pages.owner, locale.id, 'subpath'));
      const snapshot = () => page.evaluate(() => ({ width: innerWidth, dpr: devicePixelRatio,
        scroll: document.documentElement.scrollWidth,
        body: [...document.querySelectorAll('aside.cj-admonition')].map(element => element.textContent),
        badges: [...document.querySelectorAll('.cj-risk')].map(element => element.textContent),
      }));
      const before = await snapshot();
      const zoom = await worker.evaluate(async url => {
        const tab = (await chrome.tabs.query({})).find(tab => tab.url === url);
        if (!tab) throw new Error('acceptance tab missing');
        await chrome.tabs.setZoom(tab.id, 2);
        return chrome.tabs.getZoom(tab.id);
      }, page.url());
      expect(zoom).toBe(2);
      await expect.poll(() => page.evaluate(() => devicePixelRatio)).toBe(before.dpr * 2);
      const after = await snapshot();
      expect(after.width).toBeCloseTo(before.width / 2, 0);
      expect(after.scroll).toBeLessThanOrEqual(after.width);
      expect(after.body).toEqual(before.body);
      expect(after.badges).toEqual(before.badges);
      const { details, summary } = await memberDetails(page, locale);
      await summary.focus();
      await page.keyboard.press('Enter');
      await expect(details.locator('aside.cj-admonition[data-admonition-level="danger"]')).toBeVisible();
      await expect(summary).toBeFocused();
      const session = await context.newCDPSession(page);
      const screenshot = await session.send('Page.captureScreenshot', {
        format: 'png', fromSurface: true, captureBeyondViewport: false,
      });
      await writeFile(info.outputPath(`${locale.id}-native-zoom200.png`), Buffer.from(screenshot.data, 'base64'));
      await session.detach();
      await writeFile(info.outputPath(`${locale.id}-native-zoom.json`), JSON.stringify({ zoom, before, after }, null, 2));
      await worker.evaluate(async url => {
        const tab = (await chrome.tabs.query({})).find(tab => tab.url === url);
        await chrome.tabs.setZoom(tab.id, 1);
      }, page.url());
      await page.close();
    }
  } finally {
    await context.close();
    await rm(profile, { recursive: true, force: true });
    await rm(extension, { recursive: true, force: true });
  }
});
