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

// The member controls are siblings of native <details>, never children
// of its hidden body or its interactive <summary>.
function memberActions(member) {
  return member.locator('xpath=..').locator(':scope > .member-detail-actions');
}

async function openReferenceBox(page) {
  await openIndex(page);
  const packageHref = await page.locator('.package-index a').first().getAttribute('href');
  const packageUrl = new URL(packageHref, indexUrl).href;
  await gotoFile(page, packageUrl);
  const classHref = await referenceBoxClassHref(page);
  const classUrl = new URL(classHref, packageUrl).href;
  await gotoFile(page, classUrl);
  return classUrl;
}

async function expectMemberSectionCounts(page, chinese) {
  const groups = await page.locator('[data-cjdoc-member-group]').evaluateAll(nodes => nodes.map(group => {
    const rows = [...group.querySelectorAll('[data-cjdoc-member]')];
    return {
      total: rows.length,
      matches: rows.filter(row => !row.hidden).length,
      hidden: group.hidden,
      text: group.querySelector('.member-group-count').textContent,
    };
  }));
  expect(groups.length).toBeGreaterThan(0);
  for (const group of groups) {
    const count = group.matches === group.total ? String(group.total) : `${group.matches} / ${group.total}`;
    expect(group.text).toBe(count + (chinese ? ' 个成员' : ' members'));
    expect(group.hidden).toBe(group.matches === 0);
  }
  return groups;
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

  for (const width of [1440, 390]) {
    test(`eight theme choices persist and keep keyboard controls usable at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 });
      await openIndex(page);
      const trigger = page.locator('[data-cjdoc-theme-toggle]');
      const popover = page.locator('[data-cjdoc-theme-popover]');
      for (const theme of ['system', 'light', 'dark', 'paper', 'ocean', 'forest', 'terminal', 'violet']) {
        await trigger.click();
        await expect(popover.locator('[data-cjdoc-theme-value]')).toHaveCount(8);
        await popover.locator(`[data-cjdoc-theme-value="${theme}"]`).click();
        await expect(popover).toBeHidden();
        await expect(trigger).toBeFocused();
        expect(await page.evaluate(() => localStorage.getItem('cjdoc-theme'))).toBe(theme);
        await page.reload();
        if (theme === 'system') await expect(page.locator('html')).not.toHaveAttribute('data-theme');
        else await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
        expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width + 1);
        if (process.env.CJDOC_THEME_SCREENSHOTS) {
          await page.screenshot({path: path.join(process.env.CJDOC_THEME_SCREENSHOTS, `${width}-${theme}.png`)});
        }
      }
      await trigger.click();
      await expect(popover.locator('[data-cjdoc-theme-value="violet"]')).toHaveAttribute('aria-pressed', 'true');
      await page.keyboard.press('Escape');
      await expect(popover).toBeHidden();
      await expect(trigger).toBeFocused();
      if (width === 390) {
        await trigger.click();
        await expect(popover).toHaveAttribute('aria-modal', 'true');
        const buttons = popover.locator('button');
        await buttons.last().focus();
        await page.keyboard.press('Tab');
        await expect(buttons.first()).toBeFocused();
        await page.keyboard.press('Shift+Tab');
        await expect(buttons.last()).toBeFocused();
        await page.locator('[data-cjdoc-theme-backdrop]').click({position: {x: 5, y: 5}});
        await expect(popover).toBeHidden();
        await expect(trigger).toBeFocused();
      }
      for (const shortcut of ['Control+k', 'Meta+k']) {
        await trigger.click();
        await page.keyboard.press(shortcut);
        await expect(popover).toBeHidden();
        await expect(page.locator('[data-cjdoc-search]')).toBeFocused();
        await expect(page.locator('.site-search')).not.toHaveAttribute('inert', '');
        await page.keyboard.press('Escape');
      }
      await expectStable(page);
    });
  }

  test.beforeEach(async ({ page }) => {
    const errors = [];
    pageErrors.set(page, errors);
    page.on('pageerror', error => errors.push(String(error)));
  });
  test('overview, search state, typography, theme, and API routes are observable', async ({ page }) => {
    await openIndex(page);
    await expect(page.locator('body')).toHaveAttribute('data-cjdoc-route', 'overview');
    await expect(page.locator('main h1')).toContainText('API documentation');
    await expect(page.locator('.conceptual-entry')).toContainText('Open conceptual documentation');
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
    // Select the owner-level guide section by its reader-facing heading, not a layout parent.
    const classUsages = page.locator('main .api-usages').filter({
      has: page.getByRole('heading', { level: 2 }),
    });
    const classExternalDocs = page.locator('.content-column > .external-documentation');
    await expect(classUsages).toContainText('Getting started');
    await expect(classUsages).toHaveCount(1);
    const classGuide = classUsages.getByRole('link', { name: 'Getting started', exact: true });
    await expect(classGuide).toHaveCount(1);
    await expect(classGuide).toHaveAttribute('href', '../concepts/guides/getting-started.html');
    await classGuide.click();
    await expect(page).toHaveURL(new URL('../concepts/guides/getting-started.html', classUrl).href);
    await expect(page.locator('.page-header h1')).toHaveText('Getting started');
    await page.goBack();
    await expect(page).toHaveURL(classUrl);
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
    await extensionMember.first().locator('.member-detail-summary .member-display-name').click();
    await expect(extensionMember.first().locator('.extension-conditions')).toContainText('extension target');
    await originFilter.selectOption('');
    await memberFilter.fill('normalize');
    await expect(page.locator('[data-cjdoc-member][data-member-name="normalize"]')).toBeVisible();
    await expect(page.locator('[data-cjdoc-member][data-member-name="label"]')).toBeHidden();
    await expect(page.locator('[data-cjdoc-member-filter-status]')).toContainText('matching member');
    const normalizeForRestore = page.locator('details[data-cjdoc-member][data-member-name="normalize"]');
    await normalizeForRestore.locator('.member-detail-summary .member-display-name').click();
    const restoreHref = await memberActions(normalizeForRestore).locator('.member-permalink').getAttribute('href');
    expect(restoreHref).toBeTruthy();
    await page.evaluate(() => window.scrollTo(0, Math.min(520, document.documentElement.scrollHeight - innerHeight)));
    const readingY = await page.evaluate(() => window.scrollY);
    await memberActions(normalizeForRestore).locator('.member-permalink').click();
    await expect(page.locator('.sidebar-context')).toBeVisible();
    await expect(page.locator('.sidebar-context .context-item[aria-current="page"]')).toContainText('normalize');
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
    await normalizeDetail.locator('.member-detail-summary .member-display-name').click();
    await expect(normalizeDetail).not.toHaveAttribute('open', '');
    const typePageUrl = page.url();
    await normalizeDetail.locator('.member-detail-summary .member-display-name').click();
    await expect(normalizeDetail).toHaveAttribute('open', '');
    await expect(normalizeDetail.locator('.member-detail-body')).toContainText('Parameters');
    await expect(normalizeDetail.locator('.member-detail-body')).toContainText('Returns');
    await expect(normalizeDetail.locator('.member-detail-body')).toContainText('precondition');
    expect(page.url()).toBe(typePageUrl);
    await labelDetail.locator('.member-detail-summary .member-display-name').click();
    await expect(labelDetail).toHaveAttribute('open', '');
    await expect(labelDetail.locator('.api-usages')).toContainText('Getting started');
    const actions = memberActions(labelDetail);
    await expect(actions).toHaveAttribute('role', 'group');
    await expect(actions).toHaveAttribute('aria-label', 'Member actions');
    const labelSummaryId = await labelDetail.locator('.member-detail-summary').getAttribute('id');
    expect(labelSummaryId).toMatch(/-summary$/);
    await expect(actions).toHaveAttribute('aria-labelledby', new RegExp(labelSummaryId + '$'));
    await expect(actions).toHaveAccessibleName(/Member actions for.*label/);
    for (const selector of [
      '.member-actions-toggle', '.member-permalink', '.member-source-link', '.member-action-copy',
    ]) {
      await expect(actions.locator(selector)).toHaveAttribute(
        'aria-labelledby', new RegExp(labelSummaryId + '$')
      );
    }
    await expect(actions.locator('.member-permalink'))
      .toHaveAccessibleName(/Open standalone API page.*label/);
    await expect(actions.locator('.member-source-link'))
      .toHaveAccessibleName(/View source code.*label/);
    await expect(actions.locator('.member-action')).toHaveCount(3);
    // The touch disclosure contributes one extra decorative glyph.
    await expect(actions.locator('.member-action-glyph[aria-hidden="true"]')).toHaveCount(4);
    await expect(actions.locator('.member-permalink')).toHaveAttribute('aria-label', 'Open standalone API page');
    await expect(actions.locator('.member-permalink')).toHaveAttribute('title', 'Open standalone API page');
    await expect(actions.locator('.member-source-link')).toHaveAttribute('aria-label', 'View source code');
    await expect(actions.locator('.member-source-link')).toHaveAttribute('title', 'View source code');
    await expect(actions.locator('.member-source-link')).toHaveAttribute('href', /github.com\/example\/reference\/blob\//);
    await expect(actions.locator('.member-action-copy')).toHaveAttribute('aria-label', 'Copy link');
    await expect(actions.locator('.member-action-copy')).toHaveAttribute('title', 'Copy link');
    await expect(actions.locator('.member-action-label')).toHaveText(['Open standalone API page', 'View source code', 'Copy link']);
    const minActionHeight = await actions.locator('.member-action').evaluateAll(
      (elements) => Math.min(...elements.map(element => element.getBoundingClientRect().height))
    );
    expect(minActionHeight).toBeGreaterThanOrEqual(36);
    await actions.locator('.member-action-copy').focus();
    await expect(actions.locator('.member-action-copy')).toBeFocused();
    await actions.locator('.member-action-copy').click();
    await expect(actions.locator('.member-action-copy')).toHaveAttribute('data-copied', 'true');
    await expect(actions.locator('.member-action-copy')).toHaveAttribute('aria-label', 'Link copied');
    await expect(actions.locator('[data-cjdoc-copy-status]')).toHaveText('Link copied');
    // Copy feedback must not replace the copy icon with a text button.
    await expect(actions.locator('.member-action-copy .member-action-glyph')).toHaveCount(1);
    await expect(normalizeDetail).toHaveAttribute('open', '');
    await expect(page.locator('.overload-group-label')).toHaveCount(2);
    const overloadGroups = page.locator('[data-cjdoc-overload-group]');
    await expect(overloadGroups).toHaveCount(2);
    const pingDetails = page.locator('details[data-cjdoc-member][data-member-name="ping"]');
    const pingGroup = overloadGroups.filter({ has: pingDetails.first() });
    await expect(pingGroup).toHaveCount(1);
    await expect(pingGroup).toHaveAttribute('data-overload-total', '2');
    await expect(pingGroup.locator('details[data-cjdoc-member][data-member-name="ping"]')).toHaveCount(2);
    const pingSummaryIds = await pingDetails.locator(':scope > .member-detail-summary').evaluateAll(nodes => nodes.map(node => node.id));
    expect(pingSummaryIds).toHaveLength(2);
    expect(new Set(pingSummaryIds).size).toBe(2);
    for (let index = 0; index < 2; index += 1) {
      const group = memberActions(pingDetails.nth(index));
      await expect(group).toHaveAttribute('aria-labelledby', new RegExp(pingSummaryIds[index] + '$'));
    }
    await expect(pingGroup.locator('[data-cjdoc-overload-count]')).toHaveText('2 overloads');
    await expect(page.locator('details[data-cjdoc-member][data-member-name="convert"]')).toHaveCount(2);
    // Filtering does not leave empty groups or falsely report that both match.
    await memberFilter.fill('ping(value: Int64)');
    await expect(pingGroup.locator('[data-cjdoc-overload-count]')).toHaveText('1 of 2 overloads');
    await expect(pingGroup.locator('details[data-cjdoc-member][data-member-name="ping"]:not([hidden])')).toHaveCount(1);
    await memberFilter.fill('doesNotExist');
    await expect(pingGroup).toBeHidden();
    await memberFilter.fill('');
    await expect(pingGroup.locator('[data-cjdoc-overload-count]')).toHaveText('2 overloads');
    await expect(pingGroup).toBeVisible();
    await pingDetails.nth(0).locator('.member-detail-summary .member-display-name').click();
    await pingDetails.nth(1).locator('.member-detail-summary .member-display-name').click();
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
    await expect(longDetail.locator('summary .declaration-signature')).toContainText('timeoutMs!: Int64 = 1000');

    const useDetail = page.locator('details[data-cjdoc-member][data-member-name="use"]');
    const useSummary = useDetail.locator('summary .declaration-signature');
    await expect(useSummary).toHaveText('public func use(label!: String = "Token", item!: Token): Unit');
    const localTypeLink = useSummary.getByRole('link', { name: 'Token', exact: true });
    await expect(localTypeLink).toHaveCount(1);
    await expect(useDetail).not.toHaveAttribute('open', '');
    const beforeTypeNavigation = page.url();
    await localTypeLink.focus();
    await expect(localTypeLink).toBeFocused();
    await page.keyboard.press('Enter');
    await expect(page.locator('.page-header h1')).toHaveText('Token');
    await page.goBack();
    await expect(page).toHaveURL(beforeTypeNavigation);
    await expect(useDetail).not.toHaveAttribute('open', '');
    await useDetail.locator('.member-detail-summary .member-display-name').click();
    await expect(useDetail.locator('summary .declaration-signature'))
      .toContainText('label!: String = "Token", item!: Token');
    const useHref = await memberActions(useDetail).locator('.member-permalink').getAttribute('href');
    await gotoFile(page, new URL(useHref, classUrl).href);
    const useSignature = page.locator('.signature-block code');
    const linkedSignatureHtml = await useSignature.innerHTML();
    await expect(useSignature).toContainText('label!: String = "Token", item!: Token');
    expect(linkedSignatureHtml).not.toMatch(/"[^"]*<a[^>]*>Token<\/a>[^"]*"/);
    await page.goBack();
    await expectStable(page);

    await expect(page.locator('.source-action')).not.toHaveCount(0);
    await expect(page.locator('.source-action a')).toHaveAttribute('href', /github.com\/example\/reference\/blob\//);
    const memberHref = await memberActions(normalizeDetail).locator('.member-permalink').getAttribute('href');
    const memberUrl = new URL(memberHref, classUrl).href;
    await gotoFile(page, memberUrl);
    await expect(page.locator('.breadcrumbs')).toContainText('ReferenceBox');
    await expect(page.locator('.sidebar-context')).toContainText('ReferenceBox');
    await expect(page.locator('.sidebar-context .context-item[aria-current="page"]')).toContainText('normalize');
    await expect(page.locator('.sidebar-context .context-item').filter({ hasText: 'label' })).toHaveCount(1);
    await expect(page.locator('.behavior-contracts h3')).toHaveText('Behavioral constraints');
    await expect(page.locator('.behavior-contracts')).toContainText('precondition');
    await expect(page.locator('.behavior-contracts')).toContainText('performance');
    const hiddenTarget = page.locator('dt').filter({ hasText: 'HiddenGuideTarget' });
    await expect(hiddenTarget).toHaveText('HiddenGuideTarget');
    await expect(hiddenTarget.locator('a')).toHaveCount(0);
    await expect(page.locator('.toc-panel')).toContainText('Parameters');
    await expect(page.locator('.toc-panel')).toContainText('Returns');
    const copyButton = page.locator('.code-copy').first();
    await expect(copyButton).toHaveCount(1);
    await copyButton.click();
    await expect(copyButton).toHaveAttribute('data-copied', 'true');

    await gotoFile(page, classUrl);
    const labelHref = await memberActions(page.locator('details[data-cjdoc-member][data-member-name="label"]')).locator('.member-permalink').getAttribute('href');
    expect(labelHref).toBeTruthy();
    await gotoFile(page, new URL(labelHref, classUrl).href);
    await expect(page.locator('.api-usages:not(.conceptual-bindings)')).toContainText('Getting started');
    await expectStable(page);
  });

  test('package filter never creates an empty selectable option for conceptual entries', async ({ page }) => {
    await openIndex(page);
    // Conceptual pages intentionally have no package; the index fixture must
    // exercise that case or this regression would pass vacuously.
    const emptyPackageEntries = await page.evaluate(() =>
      (globalThis.__CJDOC_SEARCH_INDEX__?.entries || [])
        .filter(entry => entry.packageName === '').length);
    expect(emptyPackageEntries).toBeGreaterThan(0);

    const packageFilter = page.locator('[data-cjdoc-package]');
    const kindFilter = page.locator('[data-cjdoc-kind]');
    await expect(packageFilter).toHaveAttribute('aria-label', 'Filter by package');
    await expect(packageFilter.locator('option').first()).toHaveText('All packages');
    await expect(packageFilter.locator('option[value=""]')).toHaveCount(1);
    await expect(kindFilter.locator('option[value=""]')).toHaveCount(1);

    const options = await packageFilter.locator('option').evaluateAll(elements =>
      elements.map(option => ({value: option.value, label: option.textContent.trim()})));
    expect(options.length).toBeGreaterThan(1);
    expect(options.slice(1).every(option => option.value.trim() && option.label)).toBe(true);

    // The first ArrowDown/select action must not choose the formerly injected
    // empty option, which appeared as a blank control with the focus ring.
    await packageFilter.selectOption({index: 1});
    await expect(packageFilter).not.toHaveValue('');
    await expect(packageFilter).toHaveValue(options[1].value);
    await packageFilter.selectOption('');
    await expect(packageFilter).toHaveValue('');

    // Omitting a package is legitimate for conceptual search hits.
    await page.locator('[data-cjdoc-search]').fill('Getting started');
    await expect(page.locator('[data-cjdoc-results] [role="option"]')).not.toHaveCount(0);
  });

  test('Chinese package filter retains a readable default and nonblank choices', async ({ page }) => {
    test.skip(!zhIndexUrl, 'CJDOC_HTML_FIXTURE_ZH is not configured');
    pageErrors.set(page, []);
    page.on('pageerror', error => pageErrors.get(page).push(String(error)));
    await page.goto(zhIndexUrl);
    await expectStable(page);
    const packageFilter = page.locator('[data-cjdoc-package]');
    await expect(packageFilter.locator('option').first()).toHaveText('全部包');
    await expect(packageFilter.locator('option[value=""]')).toHaveCount(1);
    const labels = await packageFilter.locator('option').evaluateAll(elements =>
      elements.slice(1).map(option => option.textContent.trim()));
    expect(labels.length).toBeGreaterThan(0);
    expect(labels.every(Boolean)).toBe(true);
    await packageFilter.selectOption({index: 1});
    await expect(packageFilter).not.toHaveValue('');
  });

  test('package rows expose generic identity and projected counts', async ({ page }) => {
    await openIndex(page);
    const packageHref = await page.locator('.package-index a').first().getAttribute('href');
    const packageUrl = new URL(packageHref, indexUrl).href;
    await gotoFile(page, packageUrl);
    const row = page.locator('article[data-member-name="ReferenceBox"][data-member-kind="class"]');
    await expect(row.locator('.declaration-summary-head code')).toHaveText('ReferenceBox<T>');
    await expect(row.locator('.declaration-signature')).toHaveText('public class ReferenceBox<T>');
    await expect(row.locator('.declaration-kind')).toHaveCount(0);
    await expect(row.locator('p')).toHaveCount(0);
    await expect(page.locator('#classes')).toHaveText('Classes (2)');
    const overloads = page.locator('article[data-member-name="packageOperation"]');
    await expect(overloads).toHaveCount(2);
    const signatures = await overloads.locator('.declaration-signature').allTextContents();
    expect(signatures[0]).not.toBe(signatures[1]);
    await expect(overloads.filter({hasText: 'SourceValue'}).locator('.declaration-summary-head code')).toHaveText(
      'packageOperation<SourceValue, DestinationValue>');
    await expect(overloads.filter({hasText: 'value!: Int64'}).locator('.declaration-signature')).toHaveText(
      'public func packageOperation(value!: Int64 = 42): Unit');
    expect(await page.locator('article a a').count()).toBe(0);
    const href = await row.locator('.declaration-row-link').getAttribute('href');
    await row.locator('.declaration-row-link').focus();
    await page.keyboard.press('Tab');
    await page.keyboard.press('Shift+Tab');
    await expect(row.locator('.declaration-row-link')).toBeFocused();
    await page.keyboard.press('Enter');
    await expect(page).toHaveURL(new URL(href, packageUrl).href);
    for (const viewport of [{width: 1440, height: 900}, {width: 1024, height: 768}, {width: 390, height: 844}]) {
      await page.setViewportSize(viewport);
      await gotoFile(page, packageUrl);
      const metrics = await page.evaluate(() => ({
        width: document.documentElement.clientWidth, scroll: document.documentElement.scrollWidth,
        signatures: [...document.querySelectorAll('article .declaration-signature')].every(node => {
          const style = getComputedStyle(node);
          return style.overflow !== 'hidden' && node.scrollWidth <= node.clientWidth + 1;
        }),
      }));
      const descriptions = await overloads.locator('p').evaluateAll(nodes => nodes.map(node => ({
        height: node.clientHeight, line: parseFloat(getComputedStyle(node).lineHeight),
        clipped: node.scrollHeight > node.clientHeight,
      })));
      for (const description of descriptions) {
        expect(description.height).toBeLessThanOrEqual(description.line * 2 + 1);
        expect(description.clipped).toBe(true);
      }
      expect(metrics.scroll).toBeLessThanOrEqual(metrics.width + 1);
      expect(metrics.signatures).toBe(true);
    }
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
    await expect(page.locator('.conceptual-bindings')).toContainText('Linked');
    const boundApiLinks = page.locator('.conceptual-bindings a[href*="symbols/symbol-"]');
    await expect(boundApiLinks).toHaveCount(2);
    expect(await boundApiLinks.nth(0).getAttribute('href')).not.toBe(
      await boundApiLinks.nth(1).getAttribute('href')
    );
    // Captured binding languages are machine metadata; the reader exposes the version.
    await expect(page.locator('.conceptual-bindings')).toContainText('fixture-v1');
    await expect(page.locator('.conceptual-bindings a[href="phish"]')).toHaveCount(0);
    await expect(page.locator('.conceptual-bindings')).toContainText('Not available in this audience');
    await expect(page.locator('pre').filter({ hasText: 'cjdoc-bind target="html_reference_extra.ExtraBox"' })).toHaveCount(1);
    const placement = await page.evaluate(() => {
      const index = document.querySelector('main .conceptual-bindings');
      const chips = [...document.querySelectorAll('main .inline-binding')].filter(chip => !index.contains(chip));
      const paragraph = [...document.querySelectorAll('main p')].find(node => node.textContent.includes('Choose a package from the API index'));
      const fenced = [...document.querySelectorAll('main pre')].find(node => node.textContent.includes('cjdoc-bind target="html_reference_extra.ExtraBox"'));
      const follows = (first, second) => !!(first && second && (first.compareDocumentPosition(second) & Node.DOCUMENT_POSITION_FOLLOWING));
      return { chips: chips.length, paragraphBeforeFirstChip: follows(paragraph, chips[0]),
        chipsBeforeFencedCode: chips.every(chip => follows(chip, fenced)),
        indexAfterBodyCode: follows(fenced, index) };
    });
    expect(placement).toEqual({ chips: 3, paragraphBeforeFirstChip: true, chipsBeforeFencedCode: true, indexAfterBodyCode: true });
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
    await expect(page.locator('meta[http-equiv="Content-Security-Policy"]')).toHaveAttribute(
      'content',
      "default-src 'none'; script-src 'self' file:; style-src 'self' file:; img-src 'self' file:; base-uri 'none'; form-action 'none'",
    );
    await expect(page.locator('meta[http-equiv="Content-Security-Policy"]')).toHaveCount(1);
    await expect(page.locator('script[src="theme-bootstrap.js"]')).toHaveCount(1);
    await expect(page.locator('script[src="search-index.js"]')).toHaveCount(1);
    await expect(page.locator('script[src="search.js"]')).toHaveCount(1);
  });


  test('mobile drawer, narrow TOC, filters, and CSS zoom remain usable', async ({ page }) => {
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
    await expect(page.locator('.toc-panel')).toBeHidden();
    await expect(page.locator('[data-cjdoc-mobile-toc]')).toBeVisible();
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

  test('dense type member cards retain complete signatures and bounded height', async ({ page }) => {
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
    // The redesigned cards show name, complete signature and summary on separate rows.
    expect(metrics.max).toBeLessThan(145);
    expect(metrics.average).toBeLessThan(132);
    await expect(page.locator('details[data-cjdoc-member] > summary .declaration-signature'))
      .toHaveCount(metrics.count);
  });

  test('extension page exposes owned members and accurate navigation in file and HTTP modes', async ({ page, browser }) => {
    let offlineExtensionUrl;
    for (const start of [indexUrl, httpBaseUrl + 'index.html']) {
      await page.goto(start);
      await expectStable(page);
      await page.locator('.package-index a').first().click();
      await referenceBoxClassLink(page).click();
      const typeUrl = page.url();
      const extensionMember = page.locator(
        'details[data-cjdoc-member][data-member-origin="extension"][data-member-name="extensionMarker"]'
      );
      await expect(extensionMember).toHaveCount(1);
      await extensionMember.locator('summary .member-display-name').click();
      await extensionMember.locator('.member-origin a').click();
      const extensionUrl = page.url();
      if (start === indexUrl) offlineExtensionUrl = extensionUrl;
      await expect(page.locator('main h1')).toContainText('Extension ReferenceBox<T>');
      await expect(page.locator('.breadcrumbs li[aria-current="page"]')).toContainText('Extension');
      const ownMember = page.locator('details[data-cjdoc-member][data-member-name="extensionMarker"]');
      await expect(ownMember).toHaveCount(1);
      await expect(page.locator('.sidebar-context a[href^="#"]')).toHaveCount(1);
      await ownMember.locator('summary .member-display-name').click();
      await expect(ownMember.locator('.member-detail-body')).toBeVisible();
      await expect(ownMember).toContainText('Member supplied by an extension.');
      await expect(memberActions(ownMember).locator('.member-permalink')).toHaveAttribute('href', /symbol-/);
      const target = page.locator('.symbol-relationships a.relation-target');
      await expect(target).toHaveCount(1);
      await target.click();
      await expect(page).toHaveURL(typeUrl);
      await page.goBack();
      await expect(page).toHaveURL(extensionUrl);
      if (!(await ownMember.evaluate(node => node.open))) {
        await ownMember.locator('summary .member-display-name').click();
      }
      // Desktop actions become actionable when the pointer enters their member row.
      await ownMember.hover();
      await expect(memberActions(ownMember)).toHaveCSS('pointer-events', 'auto');
      await memberActions(ownMember).locator('.member-permalink').click();
      await expect(page.locator('.breadcrumbs a').filter({ hasText: 'Extension ReferenceBox<T>' })).toHaveCount(1);
      await page.goBack();
      await expectStable(page);
    }
    const context = await browser.newContext({ javaScriptEnabled: false });
    try {
      const offlinePage = await context.newPage();
      await offlinePage.goto(offlineExtensionUrl);
      const member = offlinePage.locator('details[data-cjdoc-member][data-member-name="extensionMarker"]');
      await expect(member).toHaveCount(1);
      await member.locator('summary .member-display-name').click();
      await expect(member.locator('.member-detail-body')).toBeVisible();
      await expect(offlinePage.locator('.symbol-relationships a.relation-target')).toHaveCount(1);
    } finally {
      await context.close();
    }
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
    await convert.locator('.member-detail-summary .member-display-name').click();
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
    const memberHref = await memberActions(page.locator('[data-cjdoc-member][data-member-name="normalize"]')).locator('.member-permalink').getAttribute('href');
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

  test('member header actions work when collapsed and remain stable on hover and focus', async ({ page }) => {
    const classUrl = await openReferenceBox(page);
    const member = page.locator('details[data-cjdoc-member][data-member-name="label"]');
    const summary = member.locator('summary');
    const actions = memberActions(member);
    await expect(member).not.toHaveAttribute('open', '');
    await expect(actions).toHaveCount(1);
    await expect(actions.locator('.member-action')).toHaveCount(3);
    await expect(actions).toHaveCSS('opacity', '0');
    const before = await summary.boundingBox();
    await summary.hover();
    await expect(actions).toHaveCSS('opacity', '1');
    const after = await summary.boundingBox();
    expect(Math.abs(after.width - before.width)).toBeLessThan(1);
    expect(Math.abs(after.height - before.height)).toBeLessThan(1);
    await actions.locator('.member-action-copy').click();
    await expect(actions.locator('.member-action-copy')).toHaveAttribute('data-copied', 'true');
    await expect(member).not.toHaveAttribute('open', '');
    expect(page.url()).toBe(classUrl);

    await summary.focus();
    await page.keyboard.press('Tab');
    const signatureTypeLink = summary.getByRole('link', { name: 'String', exact: true });
    await expect(signatureTypeLink).toBeFocused();
    await page.keyboard.press('Tab');
    await expect(actions.locator('.member-permalink')).toBeFocused();
    await page.keyboard.press('Tab');
    await expect(actions.locator('.member-source-link')).toBeFocused();
    await page.keyboard.press('Tab');
    await expect(actions.locator('.member-action-copy')).toBeFocused();
    await expect(actions).toHaveCSS('opacity', '1');

    await summary.locator('.member-display-name').click();
    await expect(member).toHaveAttribute('open', '');
    await expect(member.locator('.member-detail-body')).toBeVisible();
    await expect(member.locator('.member-detail-actions')).toHaveCount(0);
    await expect(actions).toHaveCount(1);
    await actions.locator('.member-action-copy').focus();
    await expect(member).toHaveAttribute('open', '');

    // Each overload must retain its own permanent and copy target.
    const ping = page.locator('details[data-cjdoc-member][data-member-name="ping"]');
    const first = memberActions(ping.nth(0));
    const second = memberActions(ping.nth(1));
    expect(await first.locator('.member-permalink').getAttribute('href'))
      .not.toBe(await second.locator('.member-permalink').getAttribute('href'));
    expect(await first.locator('.member-action-copy').getAttribute('data-cjdoc-copy-link'))
      .not.toBe(await second.locator('.member-action-copy').getAttribute('data-cjdoc-copy-link'));
    await expectStable(page);
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
    const actions = memberActions(detail);
    const toggle = actions.locator('[data-cjdoc-member-actions-toggle]');
    await expect(toggle).toBeVisible();
    await expect(toggle).toHaveAttribute('aria-expanded', 'false');
    await toggle.tap();
    await expect(toggle).toHaveAttribute('aria-expanded', 'true');
    await expect(actions.locator('.member-permalink')).toBeVisible();
    await expect(actions.locator('.member-source-link')).toBeVisible();
    await expect(actions.locator('.member-action-copy')).toBeVisible();
    await actions.locator('.member-action-copy').tap();
    await expect(detail).not.toHaveAttribute('open', '');
    await toggle.focus();
    await page.keyboard.press('Escape');
    await expect(toggle).toHaveAttribute('aria-expanded', 'false');
    await expect(toggle).toBeFocused();
    await toggle.tap();
    await expect(toggle).toHaveAttribute('aria-expanded', 'true');
    await page.touchscreen.tap(5, 830);
    await expect(toggle).toHaveAttribute('aria-expanded', 'false');
    await detail.locator('.member-detail-summary .member-display-name').tap();
    await expect(detail).toHaveAttribute('open', '');
    expect(page.url()).toBe(before);
    const last = page.locator('details[data-cjdoc-member]').last();
    const lastActions = memberActions(last);
    await lastActions.locator('[data-cjdoc-member-actions-toggle]').tap();
    const lastMenu = lastActions.locator('.member-action-list');
    await expect(lastMenu).toBeVisible();
    const edges = await lastMenu.evaluate(node => ({
      menuBottom: node.getBoundingClientRect().bottom,
      columnBottom: node.closest('.content-column').getBoundingClientRect().bottom,
    }));
    expect(edges.menuBottom).toBeLessThanOrEqual(edges.columnBottom + 1);
    await lastActions.locator('[data-cjdoc-member-actions-toggle]').tap();
    // At a 200% equivalent CSS viewport, the overlay must also remain inside
    // the clipped content column horizontally, not just vertically.
    await page.setViewportSize({ width: 195, height: 844 });
    await lastActions.locator('[data-cjdoc-member-actions-toggle]').tap();
    const narrow = await lastMenu.evaluate(node => {
      const popup = node.getBoundingClientRect();
      const column = node.closest('.content-column').getBoundingClientRect();
      return {
        left: popup.left, right: popup.right, bottom: popup.bottom,
        columnLeft: column.left, columnRight: column.right, columnBottom: column.bottom,
      };
    });
    expect(narrow.left).toBeGreaterThanOrEqual(narrow.columnLeft - 1);
    expect(narrow.right).toBeLessThanOrEqual(narrow.columnRight + 1);
    expect(narrow.bottom).toBeLessThanOrEqual(narrow.columnBottom + 1);
    await lastActions.locator('[data-cjdoc-member-actions-toggle]').tap();
    await expectStable(page);
    await context.close();
  });

  test('touch keeps member navigation links usable without JavaScript', async ({ browser }) => {
    const context = await browser.newContext({
      viewport: { width: 390, height: 844 }, hasTouch: true, javaScriptEnabled: false,
    });
    try {
      const page = await context.newPage();
      await page.goto(indexUrl);
      const packageHref = await page.locator('.package-index a').first().getAttribute('href');
      await page.goto(new URL(packageHref, indexUrl).href);
      const classHref = await referenceBoxClassHref(page);
      await page.goto(new URL(classHref, page.url()).href);
      const member = page.locator('details[data-cjdoc-member][data-member-name="normalize"]');
      const actions = memberActions(member);
      await expect(member).not.toHaveAttribute('open', '');
      await expect(actions.locator('.member-actions-toggle')).toBeHidden();
      await expect(actions.locator('.member-action-list')).toBeVisible();
      await expect(actions.locator('.member-permalink')).toBeVisible();
      await expect(actions.locator('.member-source-link')).toBeVisible();
      await expect(actions).toHaveCSS('position', 'static');
      expect(await page.evaluate(() => document.documentElement.scrollWidth))
        .toBeLessThanOrEqual(391);
      const origin = page.url();
      const href = await actions.locator('.member-permalink').getAttribute('href');
      await actions.locator('.member-permalink').tap();
      await expect(page).toHaveURL(new URL(href, origin).href);
      await expect(page.locator('.breadcrumbs')).toContainText('ReferenceBox');
    } finally {
      await context.close();
    }
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
    await expect(page.locator('.top-actions .version-label')).toContainText('1.3.0');
    await expect(page.locator('.cjdoc-version-selector [aria-current="page"]')).toContainText('1.3.0');
  });
});

for (const chinese of [false, true]) {
  test(`member section counts follow text, origin, reset and deep links (${chinese ? 'zh' : 'en'})`, async ({ page }) => {
    test.skip(chinese && !zhIndexUrl, 'CJDOC_HTML_FIXTURE_ZH is not configured');
    pageErrors.set(page, []);
    page.on('pageerror', error => pageErrors.get(page).push(String(error)));
    const rootUrl = chinese ? zhIndexUrl : indexUrl;
    await gotoFile(page, rootUrl);
    const packageUrl = new URL(await page.locator('.package-index a').first().getAttribute('href'), rootUrl).href;
    await gotoFile(page, packageUrl);
    const classUrl = new URL(await referenceBoxClassHref(page), packageUrl).href;
    await gotoFile(page, classUrl);
    await expectMemberSectionCounts(page, chinese);
    const filter = page.locator('[data-cjdoc-member-filter]');
    const origin = page.locator('[data-cjdoc-member-origin]');
    const ping = page.locator('[data-cjdoc-member][data-member-name="ping"]').first();
    const anchor = await ping.getAttribute('id');
    await filter.fill('ping(value: Int64)');
    const partial = await expectMemberSectionCounts(page, chinese);
    expect(partial.reduce((sum, group) => sum + group.matches, 0)).toBe(1);
    expect(partial.some(group => group.matches > 0 && group.matches < group.total)).toBe(true);
    await origin.selectOption('extension');
    const combined = await expectMemberSectionCounts(page, chinese);
    expect(combined.every(group => group.matches === 0)).toBe(true);
    await filter.fill('');
    const extension = await expectMemberSectionCounts(page, chinese);
    expect(extension.reduce((sum, group) => sum + group.matches, 0)).toBeGreaterThan(0);
    await origin.selectOption('');
    const reset = await expectMemberSectionCounts(page, chinese);
    expect(reset.every(group => group.matches === group.total)).toBe(true);
    await filter.fill('doesNotExist');
    const empty = await expectMemberSectionCounts(page, chinese);
    expect(empty.every(group => group.hidden)).toBe(true);
    await page.evaluate(id => { location.hash = id; }, anchor);
    await expect(filter).toHaveValue('');
    const cleared = await expectMemberSectionCounts(page, chinese);
    expect(cleared.every(group => group.matches === group.total)).toBe(true);
  });
}
