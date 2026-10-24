import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import { chromium, entryIndex, frame, screenshot, typeEntry } from './reader-scale-metrics.mjs';

const { values } = parseArgs({ options: {
  site: { type: 'string' }, output: { type: 'string' }, locale: { type: 'string', default: 'en' }
} });
if (!values.site || !values.output) throw new Error('--site and --output are required');
const site = path.resolve(values.site);
const output = path.resolve(values.output);
await mkdir(output);
const index = await entryIndex(site);
const owner = typeEntry(index, 'reader_scale.Member500');
const target = index.entries.filter(entry => entry.qualifiedName === 'reader_scale.Member500.member0499');
assert.equal(target.length, 1, 'the native tail-member identity must be unique');
const expectedEntries = index.entries.filter(entry => entry.kind === 'function').sort((a, b) =>
  a.qualifiedName.localeCompare(b.qualifiedName) || a.id.localeCompare(b.id));
const expected = expectedEntries.map(entry => entry.href);
assert.ok(expected.length > 40, 'a real multi-page native corpus is required');
const indexUrl = pathToFileURL(path.join(site, 'index.html')).href;
const ownerUrl = pathToFileURL(path.join(site, owner.href)).href;
const browser = await chromium.launch({ args: ['--allow-file-access-from-files'] });
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: 'en-US' });
const page = await context.newPage();
const errors = [];
page.on('pageerror', error => errors.push(String(error)));
const report = { schemaVersion: 'cjdoc.reader-discovery/1', locale: values.locale, tasks: [], visuals: [] };
const links = () => page.locator('[data-cjdoc-results] li a').evaluateAll(nodes => nodes.map(node => node.getAttribute('href')));
const query = value => page.locator('[data-cjdoc-search]').fill(value);
const next = page.locator('[data-cjdoc-search-next]');
const previous = page.locator('[data-cjdoc-search-previous]');
try {
  await page.goto(indexUrl);
  await query('kind:function');
  assert.equal(await previous.isDisabled(), true);
  const found = [];
  for (let offset = 0; offset < expected.length; offset += 20) {
    const current = await links();
    assert.deepEqual(current, expected.slice(offset, offset + 20), 'pages must preserve native identity, order and completeness');
    assert.ok(current.length > 0 && current.length <= 20);
    found.push(...current);
    assert.equal(await next.isDisabled(), offset + 20 >= expected.length);
    if (offset + 20 < expected.length) await next.click();
  }
  assert.deepEqual(found, expected);
  await previous.click();
  assert.deepEqual(await links(), expected.slice(Math.floor((expected.length - 1) / 20 - 1) * 20,
    Math.floor((expected.length - 1) / 20) * 20));
  await query('name:member0499 owner:Member500');
  assert.deepEqual(await links(), [target[0].href], 'a changed query must discard the old page offset');
  assert.equal(await page.locator('[data-cjdoc-search-pages]').isVisible(), false);
  report.tasks.push({ id: 'all-pages-native-order-and-query-reset', pass: true, matches: found.length,
    pages: Math.ceil(found.length / 20), maximumRendered: 20 });
  await query('kind:function');
  await next.click();
  await page.locator('[data-cjdoc-kind]').selectOption('function');
  assert.deepEqual(await links(), expected.slice(0, 20), 'kind changes must reset pagination');
  await next.click();
  await page.locator('[data-cjdoc-package]').selectOption(target[0].packageName);
  assert.deepEqual(await links(), expectedEntries.filter(entry => entry.packageName === target[0].packageName)
    .slice(0, 20).map(entry => entry.href), 'package changes must reset pagination');
  await page.locator('[data-cjdoc-package]').selectOption('');
  await page.locator('[data-cjdoc-kind]').selectOption('');
  report.tasks.push({ id: 'kind-and-package-reset', pass: true });
  await query('kind:function');
  const keyboardField = page.locator('[data-cjdoc-search]');
  await keyboardField.press('ArrowUp');
  await keyboardField.press('Enter');
  await page.waitForURL(new URL(expected[19], indexUrl).href);
  await page.goto(indexUrl);
  report.tasks.push({ id: 'arrow-up-wraps-to-last-visible-native-result', pass: true });

  await query('kind:function');
  await next.click();
  await page.keyboard.press('ArrowDown');
  assert.equal(await page.locator('[data-cjdoc-results] li a').nth(1)
    .evaluate(link => link === document.activeElement), true,
    'ArrowDown must move actual result focus after pagination');
  await page.keyboard.press('ArrowUp');
  assert.equal(await page.locator('[data-cjdoc-results] li a').first()
    .evaluate(link => link === document.activeElement), true);
  await keyboardField.focus();
  assert.deepEqual(await links(), expected.slice(20, 40),
    'returning focus to the query must not reset the current result page');
  await keyboardField.press('Control+k');
  assert.deepEqual(await links(), expected.slice(20, 40),
    'the search shortcut must preserve the current result page');
  await keyboardField.press('ArrowDown');
  await keyboardField.press('Enter');
  await page.waitForURL(new URL(expected[21], indexUrl).href);
  await page.goto(indexUrl);
  await query('kind:function');
  await next.click();
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('[data-cjdoc-search-popover]').isVisible(), false,
    'Escape from a paged result must dismiss the search');
  assert.equal(await keyboardField.evaluate(input => input === document.activeElement), true,
    'dismissing a focused result must return focus to the search control');
  report.tasks.push({ id: 'paged-result-keyboard-and-query-refocus', pass: true });

  await query('kind:function');
  const field = page.locator('[data-cjdoc-search]');
  await field.dispatchEvent('compositionstart');
  await field.fill('name:member0499 owner:Member500');
  await field.press('Enter');
  assert.equal(page.url(), indexUrl, 'Enter must commit an IME composition, not follow a result');
  assert.deepEqual(await links(), expected.slice(0, 20));
  await field.dispatchEvent('compositionend');
  assert.deepEqual(await links(), [target[0].href]);
  await field.press('ArrowDown');
  await field.press('Enter');
  await page.waitForURL(new URL(target[0].href, indexUrl).href);
  await page.goto(ownerUrl);
  const tail = page.locator('[data-cjdoc-member][data-member-name="member0499"]');
  const tailAnchor = await tail.getAttribute('id');
  assert.ok(tailAnchor, 'use the rendered native anchor, never guess one from a signature');
  await page.locator('[data-cjdoc-member-filter]').fill('member0000');
  assert.equal(await tail.isVisible(), false);
  await page.goto(new URL('#' + tailAnchor, ownerUrl).href);
  await page.waitForFunction(id => {
    const member = document.getElementById(id);
    return member?.open && !member.hidden;
  }, tailAnchor);
  assert.equal(await page.locator('[data-cjdoc-member-filter]').inputValue(), '');
  await page.waitForFunction(id => {
    const summary = document.getElementById(id)?.querySelector(":scope > summary");
    if (!summary) return false;
    const box = summary.getBoundingClientRect();
    return box.bottom > 64 && box.top >= 0 && box.top < innerHeight;
  }, tailAnchor);
  const tailContract = await tail.innerText();
  assert.ok(tailContract.includes(target[0].summary), 'the opened contract includes its native author summary');
  const firstMember = page.locator('[data-cjdoc-member][data-member-name="member0000"]');
  await firstMember.locator(':scope > summary').click();
  await frame(page);
  assert.equal(await firstMember.getAttribute('open'), '');
  assert.equal(await tail.getAttribute('open'), '');
  assert.equal(await tail.innerText(), tailContract,
    'opening a distant member must not discard the already-open tail contract from rendered text');
  report.tasks.push({ id: 'distant-open-contract-retains-complete-rendered-text', pass: true });
  // Compact action menus are a mobile affordance; desktop exposes direct actions.
  await page.setViewportSize({ width: 390, height: 844 });
  // Match the existing showcase keyboard path: expose the heading, not an
  // overlay scrolled to the viewport edge, before checking paint containment.
  await tail.locator(':scope > summary').evaluate(node =>
    node.scrollIntoView({ block: 'center', behavior: 'instant' }));
  await frame(page);
  const tailActions = tail.locator('..').locator('[data-cjdoc-member-actions]');
  await tailActions.locator('[data-cjdoc-member-actions-toggle]').click();
  assert.equal(await tailActions.locator('a').first().evaluate(link => {
    const box = link.getBoundingClientRect();
    const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
    return hit === link || link.contains(hit);
  }), true, 'offscreen layout containment must not clip the revealed member action menu');
  await page.keyboard.press('Escape');
  report.tasks.push({ id: 'mobile-tail-member-menu-not-clipped', pass: true });
  await page.setViewportSize({ width: 1440, height: 900 });
  report.tasks.push({ id: 'ime-keyboard-exact-api-page-and-hidden-tail-deep-link', pass: true, targetId: target[0].id });

  await page.locator('[data-cjdoc-member-filter]').fill('member0256');
  assert.equal(await page.locator('[data-cjdoc-member]:not([hidden])').count(), 1);
  await Promise.all([page.waitForURL(indexUrl), page.evaluate(destination => {
    const sidebar = document.querySelector('.docs-sidebar');
    sidebar.scrollTop = 160;
    // Navigate in the same task, before the scroll event can update the cache.
    location.href = destination;
  }, indexUrl)]);
  await page.goBack();
  await page.waitForFunction(() => document.querySelector('[data-cjdoc-member-filter]')?.value === 'member0256');
  assert.equal(await page.locator('[data-cjdoc-member]:not([hidden])').count(), 1);
  assert.ok(Math.abs(await page.locator('.docs-sidebar').evaluate(node => node.scrollTop) - 160) <= 2,
    'pagehide must capture sidebar scroll even before its queued scroll event');
  await page.locator('[data-cjdoc-member-filter]').fill('');
  await Promise.all([page.waitForURL(indexUrl), page.evaluate(destination => {
    window.scrollTo({top: 900, behavior: 'instant'});
    location.href = destination;
  }, indexUrl)]);
  await page.goBack();
  await page.waitForFunction(() => Math.abs(window.scrollY - 900) <= 5);
  assert.equal(await page.locator('[data-cjdoc-member-filter]').inputValue(), '');
  report.tasks.push({ id: 'immediate-navigation-sidebar-and-native-document-history', pass: true });

  const viewports = [['desktop', 1440, 900, 1], ['split', 960, 900, 1], ['mobile', 390, 844, 1],
    ['bp760', 760, 900, 1], ['bp761', 761, 900, 1], ['bp1180', 1180, 900, 1],
    ['bp1181', 1181, 900, 1], ['zoom200', 720, 450, 2]];
  for (const [name, width, height, deviceScaleFactor] of viewports) {
    for (const theme of ['light', 'dark']) {
      const visualContext = await browser.newContext({ viewport: { width, height }, deviceScaleFactor,
        colorScheme: theme, locale: 'en-US', isMobile: name === 'mobile', hasTouch: name === 'mobile' });
      try {
        const visualPage = await visualContext.newPage();
        await visualPage.goto(indexUrl);
        const mobile = visualPage.locator('[data-cjdoc-search-trigger]');
        if (await mobile.isVisible()) await mobile.click();
        await visualPage.locator('[data-cjdoc-search]').fill('kind:function');
        await visualPage.evaluate(() => document.fonts.ready);
        const layout = await visualPage.evaluate(() => {
          const popup = document.querySelector('[data-cjdoc-search-popover]');
          const box = popup.getBoundingClientRect();
          const buttons = [...popup.querySelectorAll('button')].map(button => {
            const bounds = button.getBoundingClientRect();
            return { width: bounds.width, height: bounds.height, bottom: bounds.bottom };
          });
          return { overflow: Math.max(0, document.documentElement.scrollWidth - innerWidth),
            popup: { left: box.left, right: box.right, top: box.top, bottom: box.bottom },
            viewport: { width: innerWidth, height: innerHeight }, buttons };
        });
        assert.equal(layout.overflow, 0);
        assert.ok(layout.popup.left >= 0 && layout.popup.right <= width + 1 && layout.popup.bottom <= height + 1,
          'result continuation and index boundary must fit the real viewport');
        assert.ok(layout.buttons.every(button => button.height >= 40 && button.width >= 40 && button.bottom <= height + 1));
        const image = await screenshot(visualPage, output, `${values.locale}-${name}-${theme}-search`);
        report.visuals.push({ name, theme, layout, image });
      } finally { await visualContext.close(); }
    }
  }
  assert.deepEqual(errors, [], 'native generated-page JavaScript must not fail');
  report.pass = true;
  console.log(JSON.stringify({ pass: true, tasks: report.tasks, screenshots: report.visuals.length }));
} finally {
  await writeFile(path.join(output, 'reader-discovery.json'), JSON.stringify(report, null, 2) + '\n');
  await context.close();
  await browser.close();
}
