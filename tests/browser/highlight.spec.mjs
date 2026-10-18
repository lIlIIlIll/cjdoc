import { test, expect, chromium } from '@playwright/test';
import { createServer } from 'node:http';
import { readFile, readdir, writeFile, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = path.resolve(process.env.CJDOC_HIGHLIGHT_FIXTURE || '');
if (!process.env.CJDOC_HIGHLIGHT_FIXTURE) throw new Error('CJDOC_HIGHLIGHT_FIXTURE is required');
const linkExpectation = process.env.CJDOC_HIGHLIGHT_EXPECT_TYPE_LINKS;
if (!['0', '2'].includes(linkExpectation)) throw new Error('CJDOC_HIGHLIGHT_EXPECT_TYPE_LINKS must come from the fixture identity oracle (0 or 2)');
const expectedTypeLinks = Number(linkExpectation);
const signatureSource = 'public func accept(label!: String = "Token", item!: Token): Token';
let server, origin, sample;
const themes = ['light', 'dark', 'paper', 'ocean', 'forest', 'terminal', 'violet', 'system'];

test.beforeAll(async () => {
  for (const name of await readdir(path.join(root, 'symbols'))) {
    if (!name.endsWith('.html')) continue;
    const html = await readFile(path.join(root, 'symbols', name), 'utf8');
    if (html.includes('data-language="python"') && html.includes('api-page-header')) {
      sample = 'symbols/' + name; break;
    }
  }
  if (!sample) throw new Error('generated multi-language symbol page missing');
  server = createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      if (!pathname.startsWith('/reference/')) throw new Error('bad prefix');
      const file = path.resolve(root, '.' + pathname.slice('/reference'.length));
      if (!file.startsWith(root + path.sep)) throw new Error('bad path');
      const body = await readFile(file);
      const extension = path.extname(file);
      response.setHeader('Content-Type', ({ '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.json': 'application/json' })[extension] || 'application/octet-stream');
      response.end(body);
    } catch { response.writeHead(404); response.end(); }
  });
  await new Promise(resolve => server.listen(0, 'localhost', resolve));
  origin = `http://localhost:${server.address().port}`;
});
test.afterAll(async () => { if (server) await new Promise(resolve => server.close(resolve)); });

function luminance(rgb) {
  const values = rgb.match(/[\d.]+/g).slice(0, 3).map(Number).map(n => n / 255).map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
  return values[0] * .2126 + values[1] * .7152 + values[2] * .0722;
}
function contrast(left, right) {
  const values = [luminance(left), luminance(right)].sort((a, b) => b - a);
  return (values[0] + .05) / (values[1] + .05);
}

test('file and HTTP subpath show static colors with JavaScript disabled', async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false });
  const page = await context.newPage();
  for (const url of [pathToFileURL(path.join(root, sample)).href, origin + '/reference/' + sample]) {
    const requests = [];
    page.on('request', request => requests.push(request.url()));
    await page.goto(url);
    await expect(page.locator('pre code[data-language="python"] .code-keyword').first()).toBeVisible();
    const staticColors = await page.locator('pre code[data-language="python"] .code-keyword').first().evaluate(element => ({
      token: getComputedStyle(element).color, plain: getComputedStyle(element.closest('code')).color,
    }));
    expect(staticColors.token).not.toBe(staticColors.plain);
    for (const language of ['cangjie', 'python', 'json', 'bash', 'toml', 'yaml']) {
      const colors = await page.locator(`pre code[data-language="${language}"] [class^="code-"]`).evaluateAll(elements => elements.map(element => ({
        token: getComputedStyle(element).color, plain: getComputedStyle(element.closest('code')).color,
      })));
      expect(colors.some(color => color.token !== color.plain), language).toBe(true);
    }
    const raw = await page.locator('pre code[data-language="python"]').first().getAttribute('data-cjdoc-source');
    expect(JSON.parse(raw)).toContain('中😀');
    expect(requests.some(url => /highlight|hljs|prism|shiki/i.test(new URL(url).pathname) && !url.endsWith('.html'))).toBe(false);
    expect(await page.locator('script[src*="highlight"]').count()).toBe(0);
  }
  await context.close();
});

test('copy reads original extracted bytes and leaves colored DOM intact', async ({ page, context }) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin });
  await page.goto(origin + '/reference/' + sample);
  const errors = [];
  page.on('pageerror', error => errors.push(String(error)));
  const originals = [];
  for (const code of await page.locator('pre code[data-cjdoc-source]').all()) {
    const original = JSON.parse(await code.getAttribute('data-cjdoc-source'));
    originals.push(original);
    const before = await code.innerHTML();
    await code.locator('xpath=..').locator('.code-copy').click();
    await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toBe(original);
    expect(await code.innerHTML()).toBe(before);
    // HTML normalizes newlines; clipboard must preserve the bound source bytes.
    expect(await code.textContent()).toBe(original.replace(/\r\n?/g, '\n'));
  }
  const corpus = originals.join('');
  for (const text of ['\r\n', '\t', '中😀', '<script>', '&amp;']) expect(corpus).toContain(text);
  expect(errors).toEqual([]);
});

test('real execCommand fallback preserves original CRLF rather than textarea normalization', async ({ page, context }) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin });
  await page.goto(origin + '/reference/' + sample);
  const code = page.locator('pre code[data-language="python"]').first();
  const original = JSON.parse(await code.getAttribute('data-cjdoc-source'));
  expect(original).toContain('\r\n');
  for (const text of ['\t', '中😀é', '<script>', '&amp;', '</code>']) expect(original).toContain(text);
  const before = await code.innerHTML();
  await page.evaluate(() => {
    const realClipboard = navigator.clipboard;
    globalThis.readRealClipboard = () => realClipboard.readText();
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: null });
    globalThis.realCopyEvents = [];
    window.addEventListener('copy', event => globalThis.realCopyEvents.push({
      trusted: event.isTrusted, prevented: event.defaultPrevented, text: event.clipboardData.getData('text/plain'),
    }));
  });
  await code.locator('xpath=..').locator('.code-copy').click();
  await expect.poll(() => page.evaluate(() => globalThis.readRealClipboard())).toBe(original);
  expect(await page.evaluate(() => globalThis.realCopyEvents)).toEqual([{ trusted: true, prevented: true, text: original }]);
  expect(await code.innerHTML()).toBe(before);
});

test('all theme states retain contrast and token metrics on desktop/mobile', async ({ page, browser }, info) => {
  await page.goto(origin + '/reference/' + sample);
  const contrastReport = [];
  const geometry = () => page.locator('pre code, .declaration-signature').evaluateAll(elements => elements.map(element => {
    const box = element.getBoundingClientRect();
    return { width: box.width, height: box.height, font: getComputedStyle(element).fontFamily };
  }));
  const initialGeometry = await geometry();
  const originalMarkup = await page.locator('pre code, .declaration-signature').evaluateAll(elements => elements.map(element => element.innerHTML));
  for (const theme of themes) {
    await page.emulateMedia({ colorScheme: 'dark' });
    await page.evaluate(theme => {
      if (theme === 'system') document.documentElement.removeAttribute('data-theme');
      else document.documentElement.dataset.theme = theme;
    }, theme);
    const tokens = await page.locator('pre code [class^="code-"], .declaration-signature [class^="code-"]').evaluateAll(elements => elements.map(element => {
      const style = getComputedStyle(element);
      const code = getComputedStyle(element.closest('code'));
      let background = element;
      while (background.parentElement && getComputedStyle(background).backgroundColor === 'rgba(0, 0, 0, 0)') background = background.parentElement;
      return { kind: element.className, color: style.color, background: getComputedStyle(background).backgroundColor,
        signature: !!element.closest('.signature-block, .declaration-signature'), font: style.fontFamily, parentFont: code.fontFamily,
        weight: style.fontWeight, parentWeight: code.fontWeight, fontStyle: style.fontStyle };
    }));
    expect(tokens.length).toBeGreaterThan(10);
    contrastReport.push({ theme, tokenCount: tokens.length, minimum: Math.min(...tokens.map(token => contrast(token.color, token.background))),
      colors: [...new Map(tokens.map(token => {
        const value = { kind: token.kind, signature: token.signature, color: token.color, background: token.background, contrast: contrast(token.color, token.background) };
        return [JSON.stringify(value), value];
      })).values()],
    });
    for (const token of tokens) {
      expect(contrast(token.color, token.background), `${theme} ${token.kind}`).toBeGreaterThanOrEqual(4.5);
      expect(token.weight).toBe(token.parentWeight);
      expect(token.fontStyle).toBe('normal');
      expect(token.font).toBe(token.parentFont);
    }
    const signatureKinds = [...new Set(tokens.filter(token => token.signature).map(token => token.kind))];
    expect(signatureKinds.length).toBeGreaterThan(0);
    for (const kind of signatureKinds) {
      const matching = tokens.filter(token => token.kind === kind);
      expect(matching.some(token => !token.signature), kind).toBe(true);
      expect(new Set(matching.map(token => token.color)).size, kind).toBe(1);
    }
    await page.screenshot({ path: info.outputPath('theme-' + theme + '.png') });
    expect(await geometry()).toEqual(initialGeometry);
    expect(await page.locator('pre code, .declaration-signature').evaluateAll(elements => elements.map(element => element.innerHTML))).toEqual(originalMarkup);
  }
  await writeFile(info.outputPath('contrast.json'), JSON.stringify({
    browser: browser.version(), font: await page.locator('pre code').first().evaluate(element => getComputedStyle(element).fontFamily),
    states: contrastReport,
  }, null, 2));
  for (const [name, width, height] of [['desktop', 1440, 900], ['mobile', 390, 844]]) {
    const scaledContext = await browser.newContext({ viewport: { width, height } });
    const scaledPage = await scaledContext.newPage();
    await scaledPage.goto(origin + '/reference/' + sample);
    const dimensions = await scaledPage.evaluate(() => ({ content: document.documentElement.scrollWidth, viewport: window.innerWidth }));
    expect(dimensions.content).toBeLessThanOrEqual(dimensions.viewport);
    await scaledPage.screenshot({ path: info.outputPath(name + '.png'), fullPage: true });
    if (name === 'mobile') {
      for (const theme of themes) {
        await scaledPage.emulateMedia({ colorScheme: 'dark' });
        await scaledPage.evaluate(theme => {
          if (theme === 'system') document.documentElement.removeAttribute('data-theme');
          else document.documentElement.dataset.theme = theme;
        }, theme);
        expect(await scaledPage.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
        await scaledPage.screenshot({ path: info.outputPath('mobile-theme-' + theme + '.png') });
      }
    }
    expect(await scaledPage.locator('pre code[data-language="python"]').first().textContent()).toContain('中😀');
    await scaledContext.close();
  }
});
test('native browser 200% zoom retains layout, source text and link identity', async ({}, info) => {
  const extension = info.outputPath('zoom-extension');
  await mkdir(extension, { recursive: true });
  await writeFile(path.join(extension, 'manifest.json'), JSON.stringify({
    manifest_version: 3, name: 'Native zoom acceptance', version: '1.0',
    permissions: ['tabs'], background: { service_worker: 'worker.js' },
  }));
  await writeFile(path.join(extension, 'worker.js'), 'chrome.runtime.onInstalled.addListener(() => {});');
  const context = await chromium.launchPersistentContext(info.outputPath('zoom-profile'), {
    channel: 'chromium', headless: true, viewport: null,
    args: ['--window-size=1440,900', `--disable-extensions-except=${extension}`, `--load-extension=${extension}`],
  });
  try {
    const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker');
    const page = await context.newPage();
    await page.goto(origin + '/reference/' + sample);
    const search = JSON.parse(await readFile(path.join(root, 'search-index.json'), 'utf8'));
    const linkedPage = await context.newPage();
    await linkedPage.goto(origin + '/reference/' + search.entries.find(entry => entry.name === 'accept').href);
    const snapshot = (targetPage = page) => targetPage.evaluate(() => ({
      width: innerWidth, dpr: devicePixelRatio, scroll: document.documentElement.scrollWidth,
      text: [...document.querySelectorAll('pre code')].map(code => code.textContent),
      links: [...document.querySelectorAll('.signature-type-link')].map(link => ({ text: link.textContent, href: link.href })),
      font: getComputedStyle(document.querySelector('pre code')).fontFamily,
    }));
    const before = await snapshot();
    const linkedBefore = await snapshot(linkedPage);
    expect(linkedBefore.links).toHaveLength(expectedTypeLinks);
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
    expect(after.text).toEqual(before.text);
    expect(after.links).toEqual(before.links);
    expect(after.font).toBe(before.font);
    await expect.poll(() => linkedPage.evaluate(() => devicePixelRatio)).toBe(linkedBefore.dpr * 2);
    const linkedAfter = await snapshot(linkedPage);
    expect(linkedAfter.scroll).toBeLessThanOrEqual(linkedAfter.width);
    expect(linkedAfter.links).toEqual(linkedBefore.links);
    expect(linkedAfter.font).toBe(linkedBefore.font);
    // At native zoom, Playwright clips using CSS dimensions but Chromium rasterizes
    // at the zoomed device scale. Capture the real viewport without a CSS-sized clip.
    for (const [targetPage, filename] of [[page, 'native-zoom200.png'], [linkedPage, 'native-zoom-link.png']]) {
      await targetPage.bringToFront();
      const session = await context.newCDPSession(targetPage);
      const image = await session.send('Page.captureScreenshot', { format: 'png', fromSurface: true, captureBeyondViewport: false });
      await writeFile(info.outputPath(filename), Buffer.from(image.data, 'base64'));
      await session.detach();
    }
    let exactTypeClickedAt200Percent = false;
    if (expectedTypeLinks) {
      const target = search.entries.find(entry => entry.name === 'Token' && entry.kind === 'class');
      await linkedPage.locator('.signature-block code .signature-type-link').first().click();
      await expect(linkedPage).toHaveURL(origin + '/reference/' + target.href);
      await expect(linkedPage.locator('.api-page-header h1')).toHaveText('Token');
      exactTypeClickedAt200Percent = true;
    }
    await writeFile(info.outputPath('native-zoom.json'), JSON.stringify({ zoom, before, after, linkedBefore, linkedAfter, exactTypeClickedAt200Percent }, null, 2));
  } finally {
    await context.close();
    await rm(info.outputPath('zoom-profile'), { recursive: true, force: true });
    await rm(extension, { recursive: true, force: true });
  }
});
test('reliable signature type links navigate exact identity without linking default strings', async ({ page }, info) => {
  const index = JSON.parse(await readFile(path.join(root, 'search-index.json'), 'utf8'));
  const subject = index.entries.find(entry => entry.name === 'accept');
  const target = index.entries.find(entry => entry.name === 'Token' && entry.kind === 'class');
  expect(subject).toBeTruthy();
  expect(target).toBeTruthy();
  await page.goto(origin + '/reference/' + subject.href);
  const signature = page.locator('.signature-block code');
  expect(await signature.textContent()).toBe(signatureSource);
  await expect(signature.locator('.code-string a')).toHaveCount(0);
  await expect(signature.locator('a a')).toHaveCount(0);
  const links = signature.locator('.signature-type-link');
  const expected = expectedTypeLinks;
  await expect(links).toHaveCount(expected);
  const linkOffsets = await links.evaluateAll(anchors => anchors.map(anchor => {
    const code = anchor.closest('code');
    const range = document.createRange();
    range.setStart(code, 0); range.setEndBefore(anchor);
    return range.toString().length;
  }));
  expect(linkOffsets).toEqual(expected ? [signatureSource.indexOf('item!: Token') + 'item!: '.length,
    signatureSource.lastIndexOf(': Token') + 2] : []);
  for (let index = 0; index < expected; index++) {
    await expect(links.nth(index)).toHaveText('Token');
    await expect(links.nth(index)).toHaveCSS('text-decoration-line', 'underline');
    expect(await links.nth(index).evaluate(link => link.href)).toBe(origin + '/reference/' + target.href);
  }
  if (expected) {
    await links.first().focus();
    await expect(links.first()).toBeFocused();
    await page.keyboard.press('Tab');
    await expect(links.nth(1)).toBeFocused();
    await expect(links.nth(1)).toHaveCSS('outline-style', 'solid');
    await expect(links.nth(1)).toHaveCSS('outline-width', '2px');
    await page.keyboard.press('Shift+Tab');
    await expect(links.first()).toBeFocused();
    await links.first().press('Enter');
    expect(page.url()).toBe(origin + '/reference/' + target.href);
    await expect(page.locator('.api-page-header h1')).toHaveText('Token');
    await page.goBack();
    await expect(page.locator('.signature-block code .signature-type-link')).toHaveCount(2);
    await page.reload();
    await expect(page.locator('.signature-block code .signature-type-link')).toHaveCount(2);
    await page.screenshot({ path: info.outputPath('reliable-type-links.png') });
  }
});
