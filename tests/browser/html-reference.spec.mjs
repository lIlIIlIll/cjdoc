import { test, expect } from '@playwright/test';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const fixtureRoot = process.env.CJDOC_HTML_FIXTURE;
if (!fixtureRoot) throw new Error('CJDOC_HTML_FIXTURE is required');
const indexUrl = pathToFileURL(path.resolve(fixtureRoot, 'index.html')).href;
const zhFixtureRoot = process.env.CJDOC_HTML_FIXTURE_ZH;
const zhIndexUrl = zhFixtureRoot
  ? pathToFileURL(path.resolve(zhFixtureRoot, 'index.html')).href
  : null;
const versionFixtureRoot = process.env.CJDOC_VERSION_FIXTURE;
const versionIndexUrl = versionFixtureRoot
  ? pathToFileURL(path.resolve(versionFixtureRoot, 'index.html')).href
  : null;
const pageErrors = new WeakMap();

async function openIndex(page) {
  const requests = [];
  const errors = [];
  pageErrors.set(page, errors);
  page.on('request', request => requests.push(request.url()));
  page.on('pageerror', error => errors.push(String(error)));
  await page.goto(indexUrl);
  expect(requests.filter(url => !url.startsWith('file:') && !url.startsWith('data:'))).toEqual([]);
  await expectStable(page);
  return requests;
}

async function expectStable(page) {
  await page.waitForTimeout(30);
  expect(pageErrors.get(page)).toEqual([]);
}

async function gotoFile(page, url) {
  await page.goto(url);
  await expectStable(page);
}
async function clickOutside(page) {
  const viewport = page.viewportSize();
  await page.mouse.click(5, (viewport?.height || 720) - 5);
}

function referenceBoxClassLink(page) {
  return page.locator(
    'article[data-cjdoc-member][data-member-name="ReferenceBox"][data-member-kind="class"] > .declaration-row-link'
  );
}

async function referenceBoxClassHref(page) {
  const link = referenceBoxClassLink(page);
  await expect(link).toHaveCount(1);
  return link.getAttribute('href');
}

let httpServer;
let httpBaseUrl;

test.beforeAll(async () => {
  const root = path.resolve(fixtureRoot);
  httpServer = createServer(async (request, response) => {
    try {
      const requestUrl = new URL(request.url || '/', 'http://127.0.0.1');
      if (!requestUrl.pathname.startsWith('/docs/')) {
        response.writeHead(404).end();
        return;
      }
      let relative = decodeURIComponent(requestUrl.pathname.slice('/docs/'.length));
      if (!relative) relative = 'index.html';
      if (relative.split('/').some(segment => segment === '..')) {
        response.writeHead(400).end();
        return;
      }
      const target = path.resolve(root, relative);
      if (target !== root && !target.startsWith(root + path.sep)) {
        response.writeHead(403).end();
        return;
      }
      const data = await readFile(target);
      const contentType = new Map([
        ['.html', 'text/html; charset=utf-8'],
        ['.css', 'text/css; charset=utf-8'],
        ['.js', 'text/javascript; charset=utf-8'],
        ['.json', 'application/json; charset=utf-8'],
      ]).get(path.extname(target)) || 'application/octet-stream';
      response.writeHead(200, {'Content-Type': contentType});
      response.end(data);
    } catch {
      response.writeHead(404).end();
    }
  });
  await new Promise((resolve, reject) => {
    httpServer.once('error', reject);
    httpServer.listen(0, '127.0.0.1', resolve);
  });
  const address = httpServer.address();
  httpBaseUrl = `http://127.0.0.1:${address.port}/docs/`;
});

test.afterAll(async () => {
  if (httpServer) await new Promise(resolve => httpServer.close(resolve));
});
test.describe('generated HTML reference', () => {
  test('overview, search state, typography, theme, and API routes are observable', async ({ page }) => {
    await openIndex(page);
    await expect(page.locator('body')).toHaveAttribute('data-cjdoc-route', 'overview');
    await expect(page.locator('main h1')).toContainText('API documentation');
    await expect(page.locator('.conceptual-entry')).toContainText('Start with the guide');
    await expect(page.locator('.quick-start')).toContainText('Browse the API index');
    await expect(page.locator('.package-index a')).toHaveCount(2);
    await expect(page.locator('.sidebar-link[aria-current="page"]')).toContainText('Overview');
    await gotoFile(page, indexUrl + '#packages');
    await expect(page.locator('.sidebar-link[href*="#packages"]')).toHaveAttribute('aria-current', 'page');
    await expect(page.locator('.sidebar-link[href$="index.html"]')).not.toHaveAttribute('aria-current');
    await gotoFile(page, indexUrl);

    const fontMetrics = await page.evaluate(() => {
      const body = getComputedStyle(document.body);
      const button = getComputedStyle(document.querySelector('[data-cjdoc-theme-toggle]'));
      const input = getComputedStyle(document.querySelector('[data-cjdoc-search]'));
      const heading = getComputedStyle(document.querySelector('main h1'));
      const code = getComputedStyle(document.querySelector('code'));
      return {body: body.fontFamily, button: button.fontFamily, input: input.fontFamily, heading: heading.fontFamily, code: code.fontFamily};
    });
    expect(fontMetrics.button).toBe(fontMetrics.body);
    expect(fontMetrics.input).toBe(fontMetrics.body);
    expect(fontMetrics.heading).toBe(fontMetrics.body);
    expect(fontMetrics.code).not.toBe(fontMetrics.body);

    const mutedContrast = await page.evaluate(() => {
      const channels = value => (value.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
      const luminance = color => {
        const rgb = channels(color).map(channel => channel / 255).map(channel => channel <= .03928 ? channel / 12.92 : ((channel + .055) / 1.055) ** 2.4);
        return .2126 * rgb[0] + .7152 * rgb[1] + .0722 * rgb[2];
      };
      const text = getComputedStyle(document.querySelector('.version-label')).color;
      const background = getComputedStyle(document.body).backgroundColor;
      const foregroundLuminance = luminance(text);
      const backgroundLuminance = luminance(background);
      return (Math.max(foregroundLuminance, backgroundLuminance) + .05) / (Math.min(foregroundLuminance, backgroundLuminance) + .05);
    });
    expect(mutedContrast).toBeGreaterThanOrEqual(4.5);

    const search = page.locator('[data-cjdoc-search]');
    const results = page.locator('[data-cjdoc-results] [role="option"]');
    await expect(search).toHaveAttribute('aria-expanded', 'false');
    await search.fill('ReferenceBox');
    await expect(results).not.toHaveCount(0);
    const referenceBoxResultCount = await results.count();
    expect(referenceBoxResultCount).toBeGreaterThanOrEqual(2);
    await expect(results.first()).toContainText('ReferenceBox');
    await expect(results.first().locator('.search-result-signature')).toBeVisible();
    await expect(results.first()).not.toContainText('cjdoc:v2');
    await search.press('ArrowDown');
    await expect(search).toHaveAttribute('aria-activedescendant', /cjdoc-search-result-/);
    await search.fill('no-such-declaration');
    await expect(results).toHaveCount(0);
    await expect(search).not.toHaveAttribute('aria-activedescendant');
    await search.fill('param:Int64');
    await expect(results).not.toHaveCount(0);
    await expect(results.filter({ hasText: 'normalize' })).not.toHaveCount(0);
    await search.fill('wat:foo');
    await expect(page.locator('[data-cjdoc-search-status]')).toContainText('Invalid filter');
    await search.fill('ReferenceBox');
    await clickOutside(page);
    await expect(results).toHaveCount(0);
    await expect(search).toHaveAttribute('aria-expanded', 'false');
    await search.click();
    await expect(results).toHaveCount(referenceBoxResultCount);
    await page.keyboard.press('Escape');
    await expect(search).toHaveValue('');
    await expect(results).toHaveCount(0);
    await search.fill('ReferenceBox');
    await clickOutside(page);
    await page.keyboard.press('Control+k');
    await expect(search).toBeFocused();
    await expect(results).toHaveCount(referenceBoxResultCount);

    await page.emulateMedia({ colorScheme: 'dark' });
    await page.evaluate(() => localStorage.removeItem('cjdoc-theme'));
    await page.reload();
    await expectStable(page);
    await expect(page.locator('html')).not.toHaveAttribute('data-theme');
    const systemDarkTokens = await page.evaluate(() => {
      const style = getComputedStyle(document.documentElement);
      return ['--surface', '--surface-raised', '--ink', '--muted', '--accent', '--accent-soft'].map(name => style.getPropertyValue(name));
    });
    await page.locator('[data-cjdoc-theme-toggle]').click();
    await page.locator('[data-cjdoc-theme-value="dark"]').click();
    const explicitDarkTokens = await page.evaluate(() => {
      const style = getComputedStyle(document.documentElement);
      return ['--surface', '--surface-raised', '--ink', '--muted', '--accent', '--accent-soft'].map(name => style.getPropertyValue(name));
    });
    expect(explicitDarkTokens).toEqual(systemDarkTokens);

    const packageHref = await page.locator('.package-index a').first().getAttribute('href');
    const packageUrl = new URL(packageHref, indexUrl).href;
    await gotoFile(page, packageUrl);
    await expect(page.locator('body')).toHaveAttribute('data-cjdoc-route', 'api');
    await expect(page.locator('.sidebar-link[href*="#packages"][aria-current="page"]')).toHaveCount(1);
    await expect(page.locator('.declaration-row-link')).not.toHaveCount(0);
    const classHref = await referenceBoxClassHref(page);
    const classUrl = new URL(classHref, packageUrl).href;
    await gotoFile(page, classUrl);
    await expect(page.locator('.breadcrumbs')).toContainText('Package');
    const classUsages = page.locator('main > .api-usages');
    const classExternalDocs = page.locator('main > .external-documentation');
    await expect(classUsages).toContainText('Getting started');
    await expect(classExternalDocs.locator('a')).toHaveAttribute('href', 'https://docs.example.test/1.1.3/libs/std/core/reference-box.html#referencebox');
    await expect(classExternalDocs).toContainText('version: 1.1.3');
    await expect(classExternalDocs).toContainText('format: cjdoc.symbol-index/1');
    await expect(classExternalDocs).toContainText('index: docs/std-symbol-index.json');
    await gotoFile(page, packageUrl);
    const stateHref = await page.locator('.declaration-row-link').filter({ hasText: 'ReferenceState' }).getAttribute('href');
    expect(stateHref).toBeTruthy();
    const stateUrl = new URL(stateHref, packageUrl).href;
    await gotoFile(page, stateUrl);
    await expect(page.locator('.external-documentation')).toHaveCount(0);
    await gotoFile(page, classUrl);
    await expect(page.locator('.sidebar-context')).toContainText('ReferenceBox');
    await expect(page.locator('.sidebar-context .context-item[href^="#"]').filter({ hasText: 'normalize' })).toHaveCount(1);
    const memberFilter = page.locator('[data-cjdoc-member-filter]');
    const originFilter = page.locator('[data-cjdoc-member-origin]');
    await expect(originFilter).toHaveCount(1);
    await expect(originFilter.locator('option[value="declared"]')).toHaveCount(1);
    await expect(originFilter.locator('option[value="extension"]')).toHaveCount(1);
    await originFilter.selectOption('extension');
    const extensionMember = page.locator('[data-cjdoc-member][data-member-origin="extension"]');
    await expect(extensionMember).not.toHaveCount(0);
    await expect(extensionMember.first()).toContainText('extensionMarker');
    await extensionMember.first().locator('.member-detail-summary').click();
    await expect(extensionMember.first().locator('.extension-conditions')).toContainText('extension target');
    await originFilter.selectOption('');
    await memberFilter.fill('normalize');
    await expect(page.locator('[data-cjdoc-member][data-member-name="normalize"]')).toBeVisible();
    await expect(page.locator('[data-cjdoc-member][data-member-name="label"]')).toBeHidden();
    await expect(page.locator('[data-cjdoc-member-filter-status]')).toContainText('matching member');
    const normalizeForRestore = page.locator('details[data-cjdoc-member][data-member-name="normalize"]');
    await normalizeForRestore.locator('.member-detail-summary').click();
    const restoreHref = await normalizeForRestore.locator('.member-permalink').getAttribute('href');
    expect(restoreHref).toBeTruthy();
    await page.evaluate(() => window.scrollTo(0, Math.min(520, document.documentElement.scrollHeight - innerHeight)));
    const readingY = await page.evaluate(() => window.scrollY);
    await normalizeForRestore.locator('.member-permalink').click();
    await expect(page.locator('.sibling-members')).toBeVisible();
    await page.goBack();
    await page.waitForTimeout(50);
    await expect(page.locator('[data-cjdoc-member-filter]')).toHaveValue('normalize');
    await expect(page.locator('details[data-cjdoc-member][data-member-name="normalize"]')).toHaveAttribute('open', '');
    expect(Math.abs((await page.evaluate(() => window.scrollY)) - readingY)).toBeLessThan(180);
    await memberFilter.fill('');
    const allMemberDetails = page.locator('details[data-cjdoc-member]');
    await expect(allMemberDetails).not.toHaveCount(0);
    expect(await allMemberDetails.count()).toBeGreaterThanOrEqual(20);
    const normalizeDetail = page.locator('details[data-cjdoc-member][data-member-name="normalize"]');
    const labelDetail = page.locator('details[data-cjdoc-member][data-member-name="label"]');
    // History restoration intentionally keeps the member open. Close it explicitly
    // before exercising the fresh one-action expansion path.
    await expect(normalizeDetail).toHaveAttribute('open', '');
    await normalizeDetail.locator('.member-detail-summary').click();
    await expect(normalizeDetail).not.toHaveAttribute('open', '');
    const typePageUrl = page.url();
    await normalizeDetail.locator('.member-detail-summary').click();
    await expect(normalizeDetail).toHaveAttribute('open', '');
    await expect(normalizeDetail.locator('.member-detail-body')).toContainText('Parameters');
    await expect(normalizeDetail.locator('.member-detail-body')).toContainText('Returns');
    await expect(normalizeDetail.locator('.member-detail-body')).toContainText('precondition');
    expect(page.url()).toBe(typePageUrl);
    await labelDetail.locator('.member-detail-summary').click();
    await expect(labelDetail).toHaveAttribute('open', '');
    await expect(labelDetail.locator('.api-usages')).toContainText('Getting started');
    await expect(labelDetail.locator('.member-source-link')).toHaveAttribute('href', /github.com\/example\/reference\/blob\//);
    await expect(normalizeDetail).toHaveAttribute('open', '');
    await expect(page.locator('.overload-group-label')).toHaveCount(2);
    const pingDetails = page.locator('details[data-cjdoc-member][data-member-name="ping"]');
    await expect(pingDetails).toHaveCount(2);
    await expect(page.locator('details[data-cjdoc-member][data-member-name="convert"]')).toHaveCount(2);
    await pingDetails.nth(0).locator('.member-detail-summary').click();
    await pingDetails.nth(1).locator('.member-detail-summary').click();
    await expect(pingDetails.nth(0)).toHaveAttribute('open', '');
    await expect(pingDetails.nth(1)).toHaveAttribute('open', '');
    const normalizeAnchor = await normalizeDetail.getAttribute('id');
    expect(normalizeAnchor).toBeTruthy();
    await memberFilter.fill('label');
    await page.evaluate(anchor => { location.hash = anchor; }, normalizeAnchor);
    await expect(page.locator('#' + normalizeAnchor)).toHaveAttribute('open', '');
    await expect(page.locator('[data-cjdoc-member-filter-status]')).toContainText('Filters cleared');
    await page.reload();
    await expectStable(page);
    await expect(page.locator('#' + normalizeAnchor)).toHaveAttribute('open', '');
    const deepLinkTab = await page.context().newPage();
    const deepLinkErrors = [];
    pageErrors.set(deepLinkTab, deepLinkErrors);
    deepLinkTab.on('pageerror', error => deepLinkErrors.push(String(error)));
    await gotoFile(deepLinkTab, typePageUrl + '#' + normalizeAnchor);
    await expect(deepLinkTab.locator('#' + normalizeAnchor)).toHaveAttribute('open', '');
    await deepLinkTab.close();

    const longDetail = page.locator('details[data-cjdoc-member][data-member-name="veryLongOperation"]');
    await expect(longDetail).toHaveCount(1);
    const longSummary = longDetail.locator('summary .declaration-signature');
    await expect(longSummary).toContainText('destination!: String');
    const longStyle = await longSummary.evaluate(element => ({
      whiteSpace: getComputedStyle(element).whiteSpace,
      text: element.textContent,
    }));
    expect(longStyle.whiteSpace).not.toBe('nowrap');
    expect(longStyle.text).toContain('enabled!: Bool = true');
    await longDetail.locator('.member-detail-summary').focus();
    await page.keyboard.press('Enter');
    await expect(longDetail).toHaveAttribute('open', '');
    await expect(longDetail.locator('.signature-block')).toContainText('timeoutMs!: Int64 = 1000');

    const useDetail = page.locator('details[data-cjdoc-member][data-member-name="use"]');
    await useDetail.locator('.member-detail-summary').click();
    const linkedSignatureHtml = await useDetail.locator('.signature-block code').innerHTML();
    expect(linkedSignatureHtml).toContain('&quot;Token&quot;');
    expect(linkedSignatureHtml).toMatch(/item!:\s*<a[^>]*>Token<\/a>/);
    expect(linkedSignatureHtml).not.toMatch(/&quot;<a[^>]*>Token<\/a>&quot;/);

    await expect(page.locator('.source-action')).not.toHaveCount(0);
    await expect(page.locator('.source-action a')).toHaveAttribute('href', /github.com\/example\/reference\/blob\//);
    const memberHref = await normalizeDetail.locator('.member-permalink').getAttribute('href');
    const memberUrl = new URL(memberHref, classUrl).href;
    await gotoFile(page, memberUrl);
    await expect(page.locator('.breadcrumbs')).toContainText('ReferenceBox');
    await expect(page.locator('.sidebar-context')).toContainText('ReferenceBox');
    await expect(page.locator('.sidebar-context .context-item[aria-current="page"]')).toContainText('normalize');
    await expect(page.locator('.sibling-members')).toContainText('label');
    await expect(page.locator('.sibling-members [aria-current="page"]')).toContainText('normalize');
    await expect(page.locator('.behavior-contracts')).toContainText('precondition');
    await expect(page.locator('.behavior-contracts')).toContainText('performance');
    await expect(page.locator('dt').filter({ hasText: 'HiddenGuideTarget' })).toContainText('unavailable');
    await expect(page.locator('.toc-panel')).toContainText('Parameters');
    await expect(page.locator('.toc-panel')).toContainText('Returns');
    const copyButton = page.locator('.code-copy').first();
    await expect(copyButton).toHaveCount(1);
    await copyButton.click();
    await expect(copyButton).toHaveAttribute('data-copied', 'true');

    await gotoFile(page, classUrl);
    const labelHref = await page.locator('details[data-cjdoc-member][data-member-name="label"] .member-permalink').getAttribute('href');
    expect(labelHref).toBeTruthy();
    await gotoFile(page, new URL(labelHref, classUrl).href);
    await expect(page.locator('.api-usages')).toContainText('Getting started');
    await expectStable(page);
  });

  test('conceptual pages share the shell and work without search', async ({ page }) => {
    await openIndex(page);
    const conceptUrl = new URL('concepts/index.html', indexUrl).href;
    await gotoFile(page, conceptUrl);
    await expect(page.locator('body')).toHaveAttribute('data-cjdoc-route', 'concept');
    await expect(page.locator('.page-header h1')).toContainText('Project guide');
    await expect(page.locator('[data-cjdoc-search]')).toHaveCount(1);
    await expect(page.locator('.code-copy')).toHaveCount(1);
    await page.locator('[data-cjdoc-search]').fill('ReferenceBox');
    await expect(page.locator('[data-cjdoc-results] [role="option"]')).not.toHaveCount(0);
    await page.locator('[data-cjdoc-theme-toggle]').click();
    await expect(page.locator('[data-cjdoc-theme-popover]')).toBeVisible();
    const guideUrl = new URL('concepts/guides/getting-started.html', indexUrl).href;
    await gotoFile(page, guideUrl);
    await expect(page.locator('.page-header h1')).toContainText('Getting started');
    await expect(page.locator('.breadcrumbs')).toContainText('Concepts');
    await expect(page.locator('.conceptual-bindings')).toContainText('resolved');
    const boundApiLinks = page.locator('.conceptual-bindings a[href*="symbols/symbol-"]');
    await expect(boundApiLinks).toHaveCount(2);
    expect(await boundApiLinks.nth(0).getAttribute('href')).not.toBe(
      await boundApiLinks.nth(1).getAttribute('href')
    );
    await expect(page.locator('.conceptual-bindings')).toContainText('</span><a href=phish>click</a>');
    await expect(page.locator('.conceptual-bindings a[href="phish"]')).toHaveCount(0);
    await expect(page.locator('.conceptual-bindings')).toContainText('unavailable');
    await expect(page.locator('pre').filter({ hasText: 'cjdoc-bind target="html_reference_extra.ExtraBox"' })).toHaveCount(1);
    await expectStable(page);
  });

  test('validation page states unavailable evidence without inferring success', async ({ page }) => {
    await openIndex(page);
    const validationUrl = new URL('validation.html', indexUrl).href;
    await gotoFile(page, validationUrl);
    await expect(page.locator('.page-header h1')).toContainText('Validation results');
    await expect(page.locator('body')).toHaveAttribute('data-cjdoc-route', 'utility');
    await expect(page.locator('.validation-page')).toBeVisible();
    await expect(page.locator('#cjdoc-sidebar')).toHaveCount(1);
    await expect(page.locator('.validation-page')).toContainText('not run');
    await expect(page.locator('.validation-page')).toContainText('API diff: not attached');
    await expect(page.locator('meta[http-equiv="Content-Security-Policy"]')).toHaveCount(1);
    await expect(page.locator('script[src="theme-bootstrap.js"]')).toHaveCount(1);
    await expect(page.locator('script[src="search-index.js"]')).toHaveCount(1);
    await expect(page.locator('script[src="search.js"]')).toHaveCount(1);
  });


  test('mobile drawer, narrow TOC, filters, and zoom remain usable', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await openIndex(page);
    const menu = page.locator('[data-cjdoc-menu]');
    await menu.click();
    const sidebar = page.locator('#cjdoc-sidebar');
    await expect(sidebar).toHaveAttribute('role', 'dialog');
    await expect(sidebar).toHaveAttribute('aria-modal', 'true');
    await expect(page.locator('.docs-main')).toHaveAttribute('inert', '');
    await expect(page.locator('[data-cjdoc-sidebar-close]')).toBeFocused();
    await page.keyboard.press('Escape');
    await expect(menu).toBeFocused();
    await expect(page.locator('.docs-main')).not.toHaveAttribute('inert', '');

    await page.setViewportSize({ width: 1180, height: 1000 });
    await openIndex(page);
    await expect(page.locator('[data-cjdoc-mobile-toc]')).toBeHidden();
    await expect(page.locator('[data-cjdoc-filter-toggle]')).toBeVisible();
    await page.locator('[data-cjdoc-filter-toggle]').click();
    await expect(page.locator('#cjdoc-search-filters')).toBeVisible();
    await clickOutside(page);
    await expect(page.locator('#cjdoc-search-filters')).toBeHidden();

    await page.setViewportSize({ width: 390, height: 844 });
    await openIndex(page);
    await expect(page.locator('[data-cjdoc-mobile-toc]')).toBeVisible();
    await page.evaluate(() => { document.documentElement.style.zoom = '2'; });
    const zoomMetrics = await page.evaluate(() => {
      const toggle = document.querySelector('[data-cjdoc-theme-toggle]');
      return {scrollWidth: document.documentElement.scrollWidth, clientWidth: document.documentElement.clientWidth,
        buttonWidth: toggle.getBoundingClientRect().width, buttonScrollWidth: toggle.scrollWidth};
    });
    expect(zoomMetrics.scrollWidth).toBeLessThanOrEqual(zoomMetrics.clientWidth + 1);
    expect(zoomMetrics.buttonWidth).toBeGreaterThanOrEqual(zoomMetrics.buttonScrollWidth);
    await expectStable(page);
  });

  test('dense type member browser keeps collapsed API rows compact', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await openIndex(page);
    const packageHref = await page.locator('.package-index a').first().getAttribute('href');
    const packageUrl = new URL(packageHref, indexUrl).href;
    await gotoFile(page, packageUrl);
    const classHref = await referenceBoxClassHref(page);
    const classUrl = new URL(classHref, packageUrl).href;
    await gotoFile(page, classUrl);
    const browser = page.locator('[data-cjdoc-member-browser]');
    await browser.scrollIntoViewIfNeeded();
    const metrics = await page.locator('details[data-cjdoc-member] > summary').evaluateAll(nodes => {
      const heights = nodes.map(node => node.getBoundingClientRect().height);
      return { count: heights.length, max: Math.max(...heights), average: heights.reduce((a, b) => a + b, 0) / heights.length };
    });
    expect(metrics.count).toBeGreaterThanOrEqual(20);
    expect(metrics.max).toBeLessThan(90);
    expect(metrics.average).toBeLessThan(72);
  });

  test('tablet reference content is visible without a viewport-sized blank row', async ({ page }) => {
    await page.setViewportSize({ width: 1024, height: 768 });
    await openIndex(page);
    const packageHref = await page.locator('.package-index a').first().getAttribute('href');
    const packageUrl = new URL(packageHref, indexUrl).href;
    await gotoFile(page, packageUrl);
    const classHref = await referenceBoxClassHref(page);
    const classUrl = new URL(classHref, packageUrl).href;
    await gotoFile(page, classUrl);
    const top = await page.locator('.docs-main .breadcrumbs').evaluate(element => element.getBoundingClientRect().top);
    expect(top).toBeLessThan(768);
    await expect(page.locator('.docs-main h1')).toBeVisible();
  });

  test('breakpoint layouts stay inside the viewport', async ({ page }) => {
    for (const width of [760, 761, 1180, 1181, 1440]) {
      await page.setViewportSize({ width, height: 1000 });
      await openIndex(page);
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
    }
  });
  test('Chinese API reference keeps compact member semantics', async ({ page }) => {
    test.skip(!zhIndexUrl, 'CJDOC_HTML_FIXTURE_ZH is not configured');
    pageErrors.set(page, []);
    page.on('pageerror', error => pageErrors.get(page).push(String(error)));
    await page.goto(zhIndexUrl);
    await expectStable(page);
    await expect(page.locator('html')).toHaveAttribute('lang', 'zh-CN');
    const packageHref = await page.locator('.package-index a').first().getAttribute('href');
    const packageUrl = new URL(packageHref, zhIndexUrl).href;
    await gotoFile(page, packageUrl);
    const classHref = await referenceBoxClassHref(page);
    const classUrl = new URL(classHref, packageUrl).href;
    await gotoFile(page, classUrl);
    await expect(page.locator('[data-cjdoc-member-filter]')).toHaveAttribute('placeholder', '筛选成员');
    await expect(page.locator('[data-cjdoc-member-origin] option[value="declared"]')).toContainText('直接声明');
    const convert = page.locator('[data-cjdoc-member][data-member-name="convert"]').first();
    await expect(convert).toContainText('将整数转换为文本');
    await convert.locator('.member-detail-summary').click();
    await expect(convert.locator('.member-detail-body')).toContainText('返回值');
  });

  test('HTTP subpath preserves assets, contextual navigation, and member deep links', async ({ page }) => {
    pageErrors.set(page, []);
    page.on('pageerror', error => pageErrors.get(page).push(String(error)));
    await page.goto(httpBaseUrl + 'index.html');
    await expectStable(page);
    const packageHref = await page.locator('.package-index a').first().getAttribute('href');
    await page.goto(new URL(packageHref, page.url()).href);
    const classHref = await referenceBoxClassHref(page);
    await page.goto(new URL(classHref, page.url()).href);
    const normalize = page.locator('[data-cjdoc-member][data-member-name="normalize"]');
    const anchor = await normalize.getAttribute('id');
    await page.goto(page.url().split('#')[0] + '#' + anchor);
    await expect(normalize).toHaveAttribute('open', '');
    await expect(page.locator('.sidebar-context')).toContainText('ReferenceBox');
    await expect(page.locator('link[href="../style.css"]')).toHaveCount(1);
    await expectStable(page);
  });

  test('reference routes remain usable around responsive breakpoints', async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await openIndex(page);
    const packageHref = await page.locator('.package-index a').first().getAttribute('href');
    const packageUrl = new URL(packageHref, indexUrl).href;
    await gotoFile(page, packageUrl);
    const classHref = await referenceBoxClassHref(page);
    const classUrl = new URL(classHref, packageUrl).href;
    await gotoFile(page, classUrl);
    const memberHref = await page.locator('[data-cjdoc-member][data-member-name="normalize"] .member-permalink').getAttribute('href');
    const memberUrl = new URL(memberHref, classUrl).href;
    const urls = [
      packageUrl,
      classUrl,
      memberUrl,
      new URL('concepts/guides/getting-started.html', indexUrl).href,
      new URL('validation.html', indexUrl).href,
    ];
    for (const width of [390, 760, 761, 1180, 1181, 1440]) {
      await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
      for (const url of urls) {
        await gotoFile(page, url);
        expect(await page.evaluate(() => document.documentElement.scrollWidth))
          .toBeLessThanOrEqual(width + 1);
        const mainTop = await page.locator('.docs-main').evaluate(element => element.getBoundingClientRect().top);
        expect(mainTop).toBeLessThan(page.viewportSize().height);
      }
    }
  });

  test('touch can open a member without navigating away', async ({ browser }) => {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    const page = await context.newPage();
    pageErrors.set(page, []);
    page.on('pageerror', error => pageErrors.get(page).push(String(error)));
    await page.goto(indexUrl);
    const packageHref = await page.locator('.package-index a').first().getAttribute('href');
    await page.goto(new URL(packageHref, indexUrl).href);
    const classHref = await referenceBoxClassHref(page);
    await page.goto(new URL(classHref, page.url()).href);
    const before = page.url();
    const detail = page.locator('[data-cjdoc-member][data-member-name="normalize"]');
    await detail.locator('.member-detail-summary').tap();
    await expect(detail).toHaveAttribute('open', '');
    expect(page.url()).toBe(before);
    await expectStable(page);
    await context.close();
  });

  test('version root and selector preserve explicit document identity', async ({ page }) => {
    test.skip(!versionIndexUrl, 'CJDOC_VERSION_FIXTURE is not configured');
    pageErrors.set(page, []);
    page.on('pageerror', error => pageErrors.get(page).push(String(error)));
    await page.goto(versionIndexUrl);
    await expectStable(page);
    await expect(page.locator('body')).toHaveAttribute('data-cjdoc-route', 'version-root');
    await expect(page.locator('h1')).toContainText('Choose a version');
    await expect(page.locator('.version-card')).toHaveCount(2);
    const latestHref = await page.locator('.version-card').filter({ hasText: '1.3.0' }).getAttribute('href');
    await gotoFile(page, new URL(latestHref, versionIndexUrl).href);
    await expect(page.locator('body')).toHaveAttribute('data-cjdoc-route', 'overview');
    await expect(page.locator('body')).toHaveAttribute('data-cjdoc-doc-version', '1.3.0');
    await expect(page.locator('.brand-subtitle')).toContainText('1.3.0');
    await expect(page.locator('.cjdoc-version-selector [aria-current="page"]')).toContainText('1.3.0');
  });
});