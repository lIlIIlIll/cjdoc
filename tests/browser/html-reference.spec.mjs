import { test, expect } from '@playwright/test';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const fixtureRoot = process.env.CJDOC_HTML_FIXTURE;
if (!fixtureRoot) throw new Error('CJDOC_HTML_FIXTURE is required');
const indexUrl = pathToFileURL(path.resolve(fixtureRoot, 'index.html')).href;
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
    await expect(results).toHaveCount(5);
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
    await expect(results).toHaveCount(5);
    await page.keyboard.press('Escape');
    await expect(search).toHaveValue('');
    await expect(results).toHaveCount(0);
    await search.fill('ReferenceBox');
    await clickOutside(page);
    await page.keyboard.press('Control+k');
    await expect(search).toBeFocused();
    await expect(results).toHaveCount(5);

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
    const classHref = await page.locator('.declaration-row-link').first().getAttribute('href');
    const classUrl = new URL(classHref, packageUrl).href;
    await gotoFile(page, classUrl);
    await expect(page.locator('.breadcrumbs')).toContainText('Package');
    await expect(page.locator('.api-usages')).toContainText('Getting started');
    await expect(page.locator('.external-documentation a')).toHaveAttribute('href', 'https://docs.example.test/1.1.3/libs/std/core/reference-box.html#referencebox');
    await expect(page.locator('.external-documentation')).toContainText('version: 1.1.3');
    await expect(page.locator('.external-documentation')).toContainText('format: cjdoc.symbol-index/1');
    await expect(page.locator('.external-documentation')).toContainText('index: docs/std-symbol-index.json');
    await gotoFile(page, packageUrl);
    const stateHref = await page.locator('.declaration-row-link').filter({ hasText: 'ReferenceState' }).getAttribute('href');
    expect(stateHref).toBeTruthy();
    const stateUrl = new URL(stateHref, packageUrl).href;
    await gotoFile(page, stateUrl);
    await expect(page.locator('.external-documentation')).toHaveCount(0);
    await gotoFile(page, classUrl);
    const memberFilter = page.locator('[data-cjdoc-member-filter]');
    await memberFilter.fill('normalize');
    await expect(page.locator('[data-cjdoc-member][data-member-name="normalize"]')).toBeVisible();
    await expect(page.locator('[data-cjdoc-member][data-member-name="label"]')).toBeHidden();
    await memberFilter.fill('');
    const allMemberDetails = page.locator('details[data-cjdoc-member]');
    await expect(allMemberDetails).not.toHaveCount(0);
    expect(await allMemberDetails.count()).toBeGreaterThanOrEqual(20);
    const normalizeDetail = page.locator('details[data-cjdoc-member][data-member-name="normalize"]');
    const labelDetail = page.locator('details[data-cjdoc-member][data-member-name="label"]');
    await expect(normalizeDetail).not.toHaveAttribute('open', '');
    const typePageUrl = page.url();
    await normalizeDetail.locator('summary').click();
    await expect(normalizeDetail).toHaveAttribute('open', '');
    await expect(normalizeDetail.locator('.member-detail-body')).toContainText('Parameters');
    await expect(normalizeDetail.locator('.member-detail-body')).toContainText('Returns');
    await expect(normalizeDetail.locator('.member-detail-body')).toContainText('precondition');
    expect(page.url()).toBe(typePageUrl);
    await labelDetail.locator('summary').click();
    await expect(labelDetail).toHaveAttribute('open', '');
    await expect(labelDetail.locator('.api-usages')).toContainText('Getting started');
    await expect(labelDetail.locator('.member-source-link')).toHaveAttribute('href', /github.com\/example\/reference\/blob\//);
    await expect(normalizeDetail).toHaveAttribute('open', '');
    const pingDetails = page.locator('details[data-cjdoc-member][data-member-name="ping"]');
    await expect(pingDetails).toHaveCount(2);
    await pingDetails.nth(0).locator('summary').click();
    await pingDetails.nth(1).locator('summary').click();
    await expect(pingDetails.nth(0)).toHaveAttribute('open', '');
    await expect(pingDetails.nth(1)).toHaveAttribute('open', '');
    const normalizeAnchor = await normalizeDetail.getAttribute('id');
    expect(normalizeAnchor).toBeTruthy();
    await gotoFile(page, typePageUrl + '#' + normalizeAnchor);
    await expect(page.locator('#' + normalizeAnchor)).toHaveAttribute('open', '');

    const useDetail = page.locator('details[data-cjdoc-member][data-member-name="use"]');
    await useDetail.locator('summary').click();
    const linkedSignatureHtml = await useDetail.locator('.compact-signature code').innerHTML();
    expect(linkedSignatureHtml).toContain('&quot;Token&quot;');
    expect(linkedSignatureHtml).toMatch(/item!:\s*<a[^>]*>Token<\/a>/);
    expect(linkedSignatureHtml).not.toMatch(/&quot;<a[^>]*>Token<\/a>&quot;/);

    await expect(page.locator('.source-action')).not.toHaveCount(0);
    await expect(page.locator('.source-action a')).toHaveAttribute('href', /github.com\/example\/reference\/blob\//);
    const memberHref = await normalizeDetail.locator('.member-permalink').getAttribute('href');
    const memberUrl = new URL(memberHref, classUrl).href;
    await gotoFile(page, memberUrl);
    await expect(page.locator('.breadcrumbs')).toContainText('ReferenceBox');
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
    await expect(page.locator('.conceptual-bindings a[href*="symbols/symbol-"]')).toHaveCount(1);
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
    await expect(page.locator('.validation-page h1')).toContainText('Validation results');
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
    const classHref = await page.locator('.declaration-row-link').filter({ hasText: 'ReferenceBox' }).getAttribute('href');
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
    const classHref = await page.locator('.declaration-row-link').filter({ hasText: 'ReferenceBox' }).getAttribute('href');
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