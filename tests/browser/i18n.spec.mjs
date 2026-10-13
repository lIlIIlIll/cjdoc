import { test, expect } from '@playwright/test';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const site = process.env.CJDOC_I18N_SITE;
if (!site) throw new Error('CJDOC_I18N_SITE is required for the i18n browser gate');
const root = path.resolve(site);
const manifest = JSON.parse(await readFile(path.join(root, 'site-manifest.json'), 'utf8'));
const search = JSON.parse(await readFile(path.join(root, 'html/en/search-index.json'), 'utf8'));
const member = search.entries.find(x => x.name === 'increment' && x.parameterTypes?.[0] === 'Int64');
const context = manifest.routes.find(x => x.language === 'zh-CN' && x.symbolId === member.id && x.pageId?.startsWith('context:') && !x.sectionId);
const parameter = manifest.routes.find(x => x.language === 'zh-CN' && x.symbolId === member.id && x.pageId === context.pageId && x.sectionId?.endsWith(':doc:param:value'));
const translated = manifest.routes.find(x => x.language === 'en' && x.symbolId === member.id && x.pageId === context.pageId && x.sectionId === parameter.sectionId);
const shots = process.env.CJDOC_I18N_SCREENSHOTS;
if (shots) await mkdir(shots, { recursive: true });
let server;
let base;

test.beforeAll(async () => {
  server = createServer(async (request, response) => {
    const url = new URL(request.url || '/', 'http://127.0.0.1');
    if (!url.pathname.startsWith('/docs/')) return response.writeHead(404).end();
    const relative = decodeURIComponent(url.pathname.slice(6));
    const file = path.resolve(root, relative);
    if (!file.startsWith(root + path.sep)) return response.writeHead(404).end();
    try {
      const bytes = await readFile(file);
      const ext = path.extname(file);
      response.writeHead(200, { 'Content-Type': ({ '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.json': 'application/json' })[ext] || 'application/octet-stream' });
      response.end(bytes);
    } catch { response.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}/docs/`;
});
test.afterAll(async () => { if (server) await new Promise(resolve => server.close(resolve)); });

function destination(mode, href) {
  return mode === 'file' ? pathToFileURL(path.join(root, href.split('#')[0])).href + (href.includes('#') ? '#' + href.split('#')[1] : '') : base + href;
}

for (const scenario of [
  { name: 'desktop-light-http', mode: 'http', viewport: { width: 1440, height: 900 }, colorScheme: 'light' },
  { name: 'mobile-dark-file', mode: 'file', viewport: { width: 390, height: 844 }, colorScheme: 'dark' },
  // A 720 CSS-pixel viewport at scale 2 reproduces the layout and raster size
  // of 200% desktop zoom; the receipt records this as layout emulation.
  { name: 'desktop-200-percent-layout', mode: 'http', viewport: { width: 720, height: 450 }, colorScheme: 'dark', deviceScaleFactor: 2 },
]) {
  test.describe(scenario.name, () => {
    test.use({ viewport: scenario.viewport, colorScheme: scenario.colorScheme, deviceScaleFactor: scenario.deviceScaleFactor || 1 });
    test('switch the exact inline overload and parameter, then reload and go back', async ({ page }) => {
      const errors = [];
      const requests = [];
      page.on('pageerror', e => errors.push(String(e)));
      page.on('request', r => requests.push(r.url()));
      await page.goto(destination(scenario.mode, parameter.href));
      const detail = page.locator(`details[id="${context.href.split('#')[1]}"]`);
      await expect(detail).toHaveJSProperty('open', true);
      await expect(page.locator('html')).toHaveAttribute('lang', 'zh-CN');
      const english = page.locator('.language-switcher a[hreflang="en"]');
      await expect(english).toHaveAttribute('href', new RegExp(translated.href.split('#')[1] + '$'));
      await english.focus();
      await expect(english).toBeFocused();
      if (shots) await page.screenshot({ path: path.join(shots, scenario.name + '-zh.png') });
      await page.keyboard.press('Enter');
      await expect(page.locator('html')).toHaveAttribute('lang', 'en');
      expect(page.url()).toContain(translated.href.split('#')[1]);
      await expect(page.locator(`details[id="${context.href.split('#')[1]}"]`)).toHaveJSProperty('open', true);
      await expect(page.getByText('Sapphire arithmetic marker.', { exact: false }).first()).toBeVisible();
      await page.reload();
      await expect(page.locator(`details[id="${context.href.split('#')[1]}"]`)).toHaveJSProperty('open', true);
      if (shots) await page.screenshot({ path: path.join(shots, scenario.name + '-en.png') });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
      await page.goBack();
      await expect(page.locator('html')).toHaveAttribute('lang', 'zh-CN');
      expect(errors).toEqual([]);
      expect(requests.every(url => url.startsWith('file:') || url.startsWith(base))).toBe(true);
    });
  });
}

test('search English author text, read the fallback and follow the guide binding', async ({ page }) => {
  await page.goto(base + 'html/en/index.html');
  const input = page.locator('[data-cjdoc-search]');
  await input.fill('Sapphire');
  const hit = page.locator('[data-cjdoc-results] a').first();
  await expect(hit).toBeVisible();
  await hit.click();
  await expect(page.getByText('Sapphire arithmetic marker.', { exact: false }).first()).toBeVisible();
  const add = search.entries.find(x => x.name === 'add');
  await page.goto(base + 'html/en/' + add.href);
  await expect(page.getByText('Original text: zh-CN').first()).toBeVisible();
  const guide = page.locator('[data-guide-id="start"]');
  await guide.click();
  await expect(page.getByRole('heading', { name: 'Integer arithmetic guide' })).toBeVisible();
  await page.getByRole('navigation', { name: 'Related APIs' }).getByRole('link', { name: 'language_fixture.add', exact: true }).click();
  expect(page.url()).toContain(add.href);
  if (shots) await page.screenshot({ path: path.join(shots, 'fallback-and-guide.png'), fullPage: true });
});

test('guide section identity survives translated headings', async ({ page }) => {
  const source = manifest.routes.find(x => x.language === 'zh-CN' && x.pageId === 'start' && x.sectionId === 'usage');
  const target = manifest.routes.find(x => x.language === 'en' && x.pageId === 'start' && x.sectionId === 'usage');
  await page.goto(base + source.href);
  await page.locator('.language-switcher a[hreflang="en"]').click();
  expect(decodeURIComponent(page.url())).toContain(target.href);
  await expect(page.getByRole('heading', { name: 'Usage', exact: true })).toBeVisible();
});

test('a missing translated chapter falls back to the same guide with an explicit notice', async ({ page }) => {
  const source = manifest.routes.find(x => x.language === 'zh-CN' && x.pageId === 'start' && x.sectionId === 'advanced');
  await page.goto(base + source.href);
  await expect(page.getByRole('heading', { name: '高级用法', exact: true })).toBeVisible();
  const english = page.locator('.language-switcher a[hreflang="en"]');
  await expect(english).toHaveAttribute('data-position-state', 'page-start');
  await expect(english).toHaveAttribute('title', '该语言没有对应章节，打开同一页面的开头');
  await english.click();
  expect(page.url()).toBe(base + 'html/en/concepts/guides/start.html');
  await expect(page.getByRole('heading', { name: 'Integer arithmetic guide', exact: true })).toBeVisible();
});

test('Ctrl or Command click opens the exact overload and parameter in a new tab', async ({ page, context: browserContext }) => {
  await page.goto(base + parameter.href);
  const english = page.locator('.language-switcher a[hreflang="en"]');
  await expect(english).toHaveAttribute('href', new RegExp(translated.href.split('#')[1] + '$'));
  const [opened] = await Promise.all([
    browserContext.waitForEvent('page'),
    english.click({ modifiers: ['ControlOrMeta'] }),
  ]);
  await expect(opened.locator('html')).toHaveAttribute('lang', 'en');
  expect(opened.url()).toBe(base + translated.href);
  await expect(opened.locator(`details[id="${context.href.split('#')[1]}"]`)).toHaveJSProperty('open', true);
  await expect(page.locator('html')).toHaveAttribute('lang', 'zh-CN');
  await opened.close();
});

test.describe('static offline reading', () => {
  test.use({ javaScriptEnabled: false });
  test('read authored text and switch language using a real file link', async ({ page }) => {
    await page.goto(destination('file', 'html/zh-CN/concepts/guides/start.html'));
    await expect(page.getByText('这份指南演示双语算术 API。')).toBeVisible();
    await page.locator('.language-switcher a[hreflang="en"]').click();
    await expect(page.getByText('This guide demonstrates the bilingual arithmetic API.')).toBeVisible();
  });
});
