import {test, expect} from '@playwright/test';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import {pageMetrics} from './reader-scale-metrics.mjs';
import {declarationUrl} from './generated-route.mjs';

const fixture = process.env.CJDOC_READING_FIXTURE;
test.skip(!fixture, 'CJDOC_READING_FIXTURE must point to a generated bilingual PocketKit site');
const siteManifest = fixture
  ? JSON.parse(await readFile(path.resolve(fixture, '..', 'site-manifest.json'), 'utf8'))
  : null;

function manifestSectionUrl(locale, home, pageUrl, sectionId) {
  const page = siteManifest?.routes.find(item =>
    item.language === locale && !item.symbolId && !item.sectionId &&
    new URL(item.href.replace(`html/${locale}/`, ''), home).href === pageUrl);
  if (!page?.pageId) throw new Error(`missing ${locale}/${pageUrl} page in site manifest`);
  const route = siteManifest.routes.find(item =>
    item.language === locale && item.pageId === page.pageId && item.sectionId === sectionId);
  if (!route) throw new Error(`missing ${locale}/${page.pageId}/${sectionId} route in site manifest`);
  return new URL(route.href.replace(`html/${locale}/`, ''), home).href;
}

let server, origin;
test.beforeAll(async () => {
  if (!fixture) return;
  server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url, 'http://localhost');
      const relative = decodeURIComponent(url.pathname).replace(/^\/docs\//, '/');
      const target = path.resolve(fixture, '.' + relative + (relative.endsWith('/') ? 'index.html' : ''));
      if (!target.startsWith(path.resolve(fixture) + path.sep)) throw new Error('outside fixture');
      const data = await readFile(target);
      const type = {'.html':'text/html', '.js':'text/javascript', '.css':'text/css', '.json':'application/json'}[path.extname(target)];
      response.writeHead(200, {'Content-Type':type || 'application/octet-stream'}).end(data);
    } catch { response.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
});
test.afterAll(async () => { if (server) await new Promise(resolve => server.close(resolve)); });

test('font evidence sampling releases DOM subscriptions before interaction timing', async ({page, context}) => {
  await page.goto(`${origin}/en/index.html`);
  const client = await context.newCDPSession(page);
  try {
    await client.send('Performance.enable');
    let changes = 0;
    client.on('DOM.attributeModified', () => changes++);
    const metrics = await pageMetrics(page, client);
    expect(metrics.fonts).not.toBeNull();
    changes = 0;
    await page.locator('main').evaluate(node => node.setAttribute('data-reader-probe', 'changed'));
    await client.send('Runtime.evaluate', {expression:'0'});
    expect(changes).toBe(0);
  } finally {
    await client.detach();
  }
});

test('member outline refreshes when its responsive view becomes active', async ({page}) => {
  await page.setViewportSize({width:1440,height:900});
  const urls = await routes(page, 'en', 'root');
  await page.goto(urls.api);
  const members = await page.locator('[data-cjdoc-member]').evaluateAll(nodes =>
    nodes.map(node => ({id:node.id,name:node.dataset.memberName})));
  const selected = members[0].name;
  const expected = members.filter(member => member.name === selected).map(member => member.id);
  const targets = selector => page.locator(selector).evaluateAll(nodes =>
    nodes.filter(node => !node.closest('li').hidden).map(node => node.dataset.tocTarget));
  const desktop = '[data-cjdoc-toc] .cj-toc__item--member > a';
  const mobile = '[data-cjdoc-mobile-toc] .cj-toc__item--member > a';
  await page.locator('[data-cjdoc-member-filter]').fill('name:' + selected);
  await expect.poll(() => targets(desktop)).toEqual(expected);
  await page.setViewportSize({width:960,height:900});
  await expect.poll(() => targets(mobile)).toEqual(expected);
  await page.locator('[data-cjdoc-member-filter]').fill('');
  await expect.poll(() => targets(mobile)).toEqual(members.map(member => member.id));
  await page.setViewportSize({width:1440,height:900});
  await expect.poll(() => targets(desktop)).toEqual(members.map(member => member.id));
});

test('reduced motion keeps outline activation free of new transitions', async ({page}) => {
  await page.emulateMedia({reducedMotion:'reduce'});
  await page.setViewportSize({width:1440,height:900});
  const urls = await routes(page, 'en', 'root');
  await page.goto(urls.api);
  const links = page.locator('[data-cjdoc-toc] a[data-toc-target]');
  const selected = await links.evaluateAll(nodes =>
    nodes.findIndex(node => !node.classList.contains('cj-toc__link--active')));
  const target = links.nth(selected);
  const href = await target.getAttribute('href');
  const transitions = await target.evaluate(link => {
    link.click();
    link.getBoundingClientRect();
    return link.getAnimations().map(animation => animation.transitionProperty);
  });
  expect(transitions).toEqual([]);
  await expect(page).toHaveURL(new URL(href, urls.api).href);
  await expect(target).toHaveClass(/cj-toc__link--active/);
});

async function routes(page, locale, transport) {
  const home = transport === 'file'
    ? pathToFileURL(path.resolve(fixture, locale, 'index.html')).href
    : `${origin}${transport === 'subpath' ? '/docs' : ''}/${locale}/index.html`;
  await page.goto(home);
  const pkg = new URL(await page.locator('.cj-package-index a').first().getAttribute('href'), home).href;
  await page.goto(pkg);
  const api = declarationUrl(await page.locator('.cj-decl-table__link').filter({hasText:'TextCatalog'}).first().getAttribute('href'), pkg);
  return {home, package:pkg, api, guide:new URL('concepts/guides/first-catalogue.html',home).href};
}

test('localized parameter, return, and exception descriptions keep compact alignment', async ({page}) => {
  await page.setViewportSize({width: 1440, height: 900});
  const {api} = await routes(page, 'zh-CN', 'root');
  await page.goto(api);
  const join = page.locator('details[data-member-name="join"]');
  const at = page.locator('details[data-member-name="at"]');
  for (const member of [join, at]) await member.locator(':scope > summary').press('Enter');

  const separator = join.locator('.cj-params__row');
  const index = at.locator('.cj-params__row');
  await expect(separator.locator('dt')).toHaveText('separator: String = ","');
  await expect(separator.getByRole('link', {name: 'String', exact: true})).toBeVisible();
  await expect(index.locator('dt')).toHaveText('index: Int64');
  for (const row of [separator, index, at.locator('.cj-throws__row')]) {
    const term = await row.locator('dt').boundingBox();
    const description = await row.locator('dd p').boundingBox();
    expect(Math.abs(description.y - term.y)).toBeLessThanOrEqual(1);
    expect(description.x).toBeGreaterThan(term.x + term.width);
  }
  const returns = at.locator('.cj-returns');
  const {lineHeight, descriptionTop} = await returns.evaluate(block => ({
    lineHeight: parseFloat(getComputedStyle(block).lineHeight),
    descriptionTop: block.querySelector('p').getBoundingClientRect().top - block.getBoundingClientRect().top,
  }));
  expect(descriptionTop).toBeLessThanOrEqual(lineHeight + 1);

  await page.setViewportSize({width: 390, height: 844});
  for (const row of [separator, at.locator('.cj-throws__row')]) {
    const term = await row.locator('dt').boundingBox();
    const description = await row.locator('dd p').boundingBox();
    expect(Math.abs(description.x - term.x)).toBeLessThanOrEqual(1);
    expect(description.y).toBeGreaterThanOrEqual(term.y + term.height);
  }

  const english = await routes(page, 'en', 'root');
  await page.goto(english.api);
  await join.locator(':scope > summary').press('Enter');
  await expect(separator.locator('dd')).toContainText('Translation missing.');
  await expect(separator.locator('dd p')).toHaveText('分隔符，默认是逗号，不进行转义。');
});

async function readingMetrics(page) {
  return page.evaluate(() => {
    const visible = selector => [...document.querySelectorAll(selector)].filter(n => n.checkVisibility({checkVisibilityCSS:true}));
    return {
      width:document.documentElement.clientWidth, scroll:document.documentElement.scrollWidth,
      summaries:visible('.cj-decl-table__summary,.cj-member__description').map(n => ({
        size:parseFloat(getComputedStyle(n).fontSize), full:n.scrollHeight <= n.clientHeight + 1,
        clamp:getComputedStyle(n).webkitLineClamp,
      })),
      code:visible('pre code,.cj-signature-inline').map(n => parseFloat(getComputedStyle(n).fontSize)),
      prose:visible('.cj-prose > p').map(n => parseFloat(getComputedStyle(n).fontSize)),
    };
  });
}

const authoringGuidePath = 'concepts/guides/doc-comments.html';

function authoringBinding(page, name) {
  return page.locator('.cj-guide .cj-binding > a').getByText(name, {exact: true});
}

test('authoring guide leads from the homepage to alerts and checked examples', async ({page}) => {
  await page.setViewportSize({width: 1440, height: 900});
  const {home} = await routes(page, 'zh-CN', 'root');
  const guide = new URL(authoringGuidePath, home).href;
  const alerts = manifestSectionUrl('zh-CN', home, guide, 'alerts');
  await page.goto(home);
  const intro = page.locator('.cj-home-intro');
  const sample = intro.locator('.cj-example-pair--prose');
  await expect(sample.locator('.cj-example-pair__code pre code')).toContainText('println(saved[0])');
  await expect(sample.locator('.cj-example-pair__output pre code')).toHaveText('hello');
  await expect(sample.locator('nav.cj-reading-paths')).toHaveCount(0);
  await intro.getByRole('link', {name: '编写文档注释', exact: true}).click();
  await expect(page).toHaveURL(guide);

  const article = page.locator('.cj-guide');
  await expect(article.locator('.cj-binding > .cj-bindings__state')).toHaveCount(0);
  await article.getByRole('link', {name: '提示与列表', exact: true}).first().click();
  await expect(page).toHaveURL(alerts);
  await expect(article.locator('aside.cj-admonition')).toHaveCount(3);
  for (const level of ['note', 'warning', 'danger']) {
    await expect(article.locator(`aside[data-admonition-level="${level}"]`)).toBeVisible();
  }
  await expect(article.locator('blockquote').filter({hasText: '[!DANGER]'})).toBeVisible();

  await authoringBinding(page, 'join(String)').click();
  await expect(page.locator('.cj-signature')).toContainText('separator!: String = ","');
  const joinAlerts = page.locator('main aside.cj-admonition');
  await expect(joinAlerts.locator('.cj-admonition__body')).toHaveText([
    /保留条目的插入顺序和重复项/,
    /分隔符可以包含多个字符/,
    /逗号、引号和换行不会转义/,
    /只含一个空字符串的目录都会返回空字符串/,
    /不要用连接结果覆盖原始数据/,
    /不要将结果直接写入按行解析的审计日志/,
  ]);
  const examplePair = page.locator('.cj-example .cj-example-pair--stacked');
  const codePanel = examplePair.locator('.cj-example-pair__code');
  const outputPanel = examplePair.locator('.cj-example-pair__output');
  const [codeBox, outputBox] = await Promise.all([codePanel.boundingBox(), outputPanel.boundingBox()]);
  expect(outputBox.x).toBe(codeBox.x);
  expect(outputBox.y).toBeGreaterThanOrEqual(codeBox.y + codeBox.height - 1);
  const background = panel => panel.evaluate(node => getComputedStyle(node).backgroundColor);
  expect(await background(outputPanel)).not.toBe(await background(codePanel));
  const joinOutput = outputPanel.locator('pre code');
  expect((await joinOutput.textContent()).trimEnd()).toBe('a,b\na / b\nab\nempty: []');
  await page.goBack();
  await expect(page).toHaveURL(alerts);

  await authoringBinding(page, 'window(Int64, Int64)').click();
  const unordered = page.locator('aside[data-admonition-level="note"] .cj-admonition__body ul > li');
  const ordered = page.locator('aside[data-admonition-level="warning"] .cj-admonition__body ol > li');
  await expect(unordered).toHaveText([/limit: 0/, /不会移除或重排/]);
  await expect(ordered).toHaveText([/校验起点/, /按实际长度读取/]);
  const windows = page.locator('.cj-example');
  await expect(windows).toHaveCount(4);
  for (const [i, output] of [
    'b\nc',
    'default length: 3\ntail length: 1',
    'at end: 0\nzero limit: 0\nempty catalogue: 0',
    'start=-1, limit=1: IllegalArgumentException\nstart=2, limit=1: IllegalArgumentException\nstart=0, limit=-1: IllegalArgumentException',
  ].entries()) {
    const example = windows.nth(i);
    await expect(example.getByText('预期输出', {exact: true})).toBeVisible();
    const blocks = example.locator('pre code');
    await expect(blocks).toHaveCount(i === 0 ? 3 : 2);
    expect((await blocks.last().textContent()).trimEnd()).toBe(output);
  }

  await page.goBack();
  const englishHome = new URL('../en/index.html', home).href;
  const englishGuide = new URL(authoringGuidePath, englishHome).href;
  const englishAlerts = manifestSectionUrl('en', englishHome, englishGuide, 'alerts');
  await page.locator('.cj-lang-toggle__current').click();
  await page.locator('.cj-lang-toggle a[hreflang="en"]').click();
  await expect(page).toHaveURL(englishAlerts);
  await expect(page.getByRole('heading', {name: 'Alerts and lists'})).toBeVisible();
});

test('reader preferences: group repeated API notices without crossing declaration boundaries', async ({page}) => {
  await page.setViewportSize({width: 390, height: 710});
  const {api, home} = await routes(page, 'zh-CN', 'root');
  await page.goto(api);
  const join = page.locator('details[data-member-name="join"]');
  const windowMember = page.locator('details[data-member-name="window"]');
  const boxes = join.locator('aside.cj-admonition');
  const trigger = page.locator('[data-cjdoc-theme-toggle]');
  const dialog = page.getByRole('dialog', {name: '显示'});
  const choices = dialog.getByRole('group', {name: 'API 提示'});
  const change = async name => {
    await trigger.click();
    await choices.getByRole('button', {name, exact: true}).click();
    await page.keyboard.press('Escape');
  };
  const levels = ['note', 'warning', 'danger'];
  const separate = levels.flatMap(level => [level, level]);
  const noticeLevels = () => boxes.evaluateAll(nodes => nodes.map(node => node.dataset.admonitionLevel));
  await join.locator('summary.cj-member__summary').press('Enter');
  await expect.poll(noticeLevels).toEqual(separate);
  const originalHtml = await boxes.locator('.cj-admonition__body').evaluateAll(nodes =>
    nodes.map(node => node.innerHTML));
  const anchors = await join.locator('[id^="doc-field-"]').evaluateAll(nodes =>
    nodes.filter(node => node.querySelector('aside.cj-admonition')).map(node => node.id));
  expect(anchors).toHaveLength(6);
  await change('按类型合并');
  await expect.poll(noticeLevels).toEqual(levels);
  await expect(boxes.locator('ul.cj-admonition__body > li')).toHaveCount(6);
  for (const [index, level] of levels.entries()) {
    const list = boxes.nth(index).getByRole('list');
    await expect(list.getByRole('listitem')).toHaveCount(2);
    for (const [offset, id] of anchors.slice(index * 2, index * 2 + 2).entries()) {
      const item = list.getByRole('listitem').nth(offset);
      await expect(item.locator(`[id="${id}"] > div[lang="zh-CN"]`)).toHaveCount(1);
      expect(await item.locator('.cj-admonition__body').innerHTML()).toBe(originalHtml[index * 2 + offset]);
    }
    await expect(boxes.nth(index)).toHaveAttribute('data-admonition-level', level);
  }
  await expect(join.locator('summary .cj-risk')).toHaveCount(2);
  await expect(windowMember).not.toHaveAttribute('open', '');
  await windowMember.locator('summary.cj-member__summary').press('Enter');
  await expect(windowMember.locator('aside.cj-admonition')).toHaveCount(2);
  await expect(windowMember.locator('aside.cj-admonition ol > li')).toHaveCount(2);
  await expect(windowMember.locator('aside.cj-admonition > ul')).toHaveCount(0);

  await change('逐条显示');
  await expect.poll(noticeLevels).toEqual(separate);
  expect(await boxes.locator('.cj-admonition__body').evaluateAll(nodes =>
    nodes.map(node => node.innerHTML))).toEqual(originalHtml);
  await expect(join.locator('summary .cj-risk')).toHaveCount(2);
  await change('按类型合并');

  await page.goto(new URL(authoringGuidePath, home).href);
  await expect(page.locator('.cj-guide aside.cj-admonition')).toHaveCount(3);
  await authoringBinding(page, 'join(String)').click();
  const fullPage = page.locator('main aside.cj-admonition > ul.cj-admonition__body');
  await expect(fullPage).toHaveCount(3);
  await expect(fullPage.locator(`[id="${anchors[0]}"]`)).toHaveCount(1);
  await page.reload();
  await expect(fullPage).toHaveCount(3);
  await trigger.click();
  await expect(choices.getByRole('button', {name: '按类型合并', pressed: true})).toBeVisible();
  await dialog.getByRole('button', {name: '恢复默认设置'}).click();
  await expect(choices.getByRole('button', {name: '逐条显示', pressed: true})).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(fullPage).toHaveCount(0);
  await expect(page.locator('main aside.cj-admonition')).toHaveCount(6);
});

test('authoring guide exposes classification and deprecation on real API pages', async ({page}) => {
  await page.setViewportSize({width: 1440, height: 900});
  const {home} = await routes(page, 'zh-CN', 'root');
  const guide = new URL(authoringGuidePath, home).href;
  await page.goto(guide);
  await authoringBinding(page, 'TextReader').click();
  const group = page.locator('section[data-cjdoc-declaration-group="10-cursor"]');
  await expect(group.getByRole('heading', {name: /读取位置/})).toBeVisible();
  const members = '[data-cjdoc-member]';
  const names = scope => scope.evaluateAll(nodes => nodes.map(node => node.dataset.memberName));
  expect(await names(group.locator(members))).toEqual(['read', 'rewind']);
  const read = group.locator('.cj-member-row').filter({has: page.locator('[data-member-name="read"]')});
  await expect(read.getByRole('link', {name: '游标', exact: true})).toHaveCount(1);
  await expect(read.getByRole('link', {name: '读取', exact: true})).toBeVisible();
  const originalNames = await names(page.locator(`${members}:visible`));
  const filter = page.locator('[data-cjdoc-member-filter]');
  await filter.fill('tag:cursor tag:reading');
  await expect.poll(() => names(page.locator(`${members}:visible`))).toEqual(['read']);
  await filter.fill('');
  await expect.poll(() => names(page.locator(`${members}:visible`))).toEqual(originalNames);
  await expect(group.locator('[data-member-name="rewind"]')).toBeVisible();

  await page.goBack();
  await authoringBinding(page, 'requireFirstText(TextCatalog)').click();
  const deprecation = page.locator('main .cj-deprecation-note');
  await expect(deprecation.locator('.cj-deprecation')).toHaveText('已弃用');
  await expect(deprecation.getByRole('link')).toHaveText('改用 TextCatalog.first()');
  await expect(deprecation.getByRole('link')).toHaveAttribute('href', /\/TextCatalog\/first\/index\.html$/);
  await expect(deprecation.locator('li code')).toHaveText(['None', 'Some("")', 'Some(text)', 'text']);
  await expect(page.locator('.cj-throws__row dt')).toHaveText(['IllegalStateException', 'IllegalArgumentException']);
  const authors = page.getByRole('heading', {name: '作者', exact: true});
  await expect(authors.locator('+ ul > li')).toHaveText(['PocketKit', 'Documentation team']);
  const related = page.locator('.cj-see-also__list a');
  await expect(related).toHaveText(['pocketkit.TextCatalog.first', 'pocketkit.TextCatalog.isEmpty']);
  await expect(related.nth(0)).toHaveAttribute('href', /\/TextCatalog\/first\/index\.html$/);
  await expect(related.nth(1)).toHaveAttribute('href', /\/TextCatalog\/isEmpty\/index\.html$/);
  const exceptional = page.locator('.cj-example').filter({hasText: '首项与两种异常'});
  const results = exceptional.locator('pre code').last();
  expect((await results.textContent()).trimEnd()).toBe('alpha\nempty: IllegalStateException\nblank: IllegalArgumentException');
  const quiet = page.locator('.cj-example').filter({hasText: '不打印也可以核对输出'});
  await expect(quiet.getByText(/空围栏要求没有标准输出/)).toBeVisible();
  await expect(quiet.getByText('预期无标准输出。', {exact: true})).toBeVisible();
  await expect(quiet.locator('.cj-example-pair__output pre')).toHaveCount(0);
  await expect(page.locator('.cj-example').filter({hasText: '只编译，不运行'}).locator('.cj-example-pair__output')).toHaveCount(0);
});

for (const [locale, transport] of [['en', 'file'], ['zh-CN', 'subpath']]) {
  test(`deprecation keeps the old destination and a separate migration in ${locale}/${transport}`, async ({page}) => {
    const {home} = await routes(page, locale, transport);
    await page.goto(home);
    const pkg = page.locator('.cj-package-index a').filter({hasText: 'pocketkit.authoring'}).first();
    await pkg.click();
    const label = locale === 'en' ? 'Deprecated' : '已弃用';
    const row = page.locator('[data-member-name="requireFirstText"]');
    await expect(row.locator('.cj-deprecation')).toHaveText(label);
    await expect(row.locator('.cj-decl-table__link')).toHaveAttribute('href', /\/requireFirstText\/index\.html$/);
    await expect(row.locator('a.cj-replacement')).toHaveAttribute('href', /\/TextCatalog\/first\/index\.html$/);
    const statusOnly = page.locator('[data-member-name="firstTextOrEmpty"]');
    await expect(statusOnly.locator('.cj-deprecation')).toHaveText(label);
    await expect(statusOnly.locator('a.cj-replacement')).toHaveCount(0);
    await expect(page.locator('.cj-tree__link').filter({hasText: 'requireFirstText'}).locator('.cj-deprecation'))
      .toHaveText(label);

    const trigger = page.locator('[data-cjdoc-search-trigger]');
    const dialog = page.locator('[data-cjdoc-search-dialog]');
    const input = dialog.getByRole('combobox', {name: locale === 'en' ? 'Search API' : '搜索 API'});
    const list = dialog.getByRole('listbox');
    const old = list.getByRole('option').filter({has: page.locator('.cj-search__hit-name', {hasText:'requireFirstText'})});
    const action = dialog.locator('a.cj-replacement');
    const selectOld = async () => {
      await input.fill('firstText');
      await expect(old.locator('.cj-deprecation')).toHaveText(label);
      const position = await old.evaluate(node => [...node.parentElement.children].indexOf(node));
      for (let i = 0; i <= position; ++i) await input.press('ArrowDown');
      await expect(action).toBeVisible();
    };
    await trigger.click();
    await selectOld();
    await expect(list.locator('a.cj-replacement')).toHaveCount(0);
    await input.press('ArrowDown');
    await expect(action).toHaveCount(0);
    await input.press('Escape');
    await expect(trigger).toBeFocused();

    await trigger.click();
    await selectOld();
    await input.press('Enter');
    await expect(page).toHaveURL(/\/requireFirstText\/(?:index\.html)?$/);
    await trigger.click();
    await selectOld();
    for (let i = 0; i < 5 && !await action.evaluate(node => node === document.activeElement); ++i) {
      await page.keyboard.press('Tab');
    }
    await expect(action).toBeFocused();
    await page.keyboard.press('Enter');
    await expect(page).toHaveURL(/\/TextCatalog\/first\/(?:index\.html)?$/);
  });
}

test('authoring guide keeps the same alerts section readable in a narrow offline file', async ({page}) => {
  await page.setViewportSize({width: 390, height: 844});
  const {home} = await routes(page, 'zh-CN', 'file');
  const guide = new URL(authoringGuidePath, home).href;
  const alerts = manifestSectionUrl('zh-CN', home, guide, 'alerts');
  await page.goto(alerts);
  await expect(page).toHaveURL(alerts);
  await expect(page.getByRole('heading', {name: '提示与列表', exact: true})).toBeVisible();
  await expect(page.locator('.cj-guide aside[data-admonition-level="note"]')).toContainText('用提示记录容易忽略的细节。');
  await expect(authoringBinding(page, 'window(Int64, Int64)')).toBeVisible();
  const metrics = await readingMetrics(page);
  expect(metrics.scroll).toBeLessThanOrEqual(metrics.width + 1);
});

test('authoring guide side-by-side examples stack on narrow screens and touch devices', async ({page, browser}) => {
  await page.setViewportSize({width: 1440, height: 900});
  const {home} = await routes(page, 'en', 'root');
  const guide = new URL(authoringGuidePath, home).href;
  const section = manifestSectionUrl('en', home, guide, 'examples');
  await page.goto(section);
  const pair = page.locator('.cj-example-pair--side-by-side');
  const code = pair.locator('.cj-example-pair__code');
  const output = pair.locator('.cj-example-pair__output');
  await expect(output.locator('pre code')).toHaveText('a / b');
  const wideCode = await code.boundingBox();
  const wideOutput = await output.boundingBox();
  expect(wideOutput.y).toBe(wideCode.y);
  expect(wideOutput.x).toBeGreaterThan(wideCode.x);

  await page.setViewportSize({width: 390, height: 844});
  const narrowCode = await code.boundingBox();
  const narrowOutput = await output.boundingBox();
  expect(narrowOutput.x).toBe(narrowCode.x);
  expect(narrowOutput.y).toBeGreaterThan(narrowCode.y);
  const {scroll, width} = await readingMetrics(page);
  expect(scroll).toBeLessThanOrEqual(width + 1);

  const mobile = await browser.newContext({isMobile: true, hasTouch: true, viewport: {width: 1040, height: 600}});
  try {
    const landscape = await mobile.newPage();
    await landscape.goto(section);
    const codeBox = await landscape.locator('.cj-example-pair__code').boundingBox();
    const outputBox = await landscape.locator('.cj-example-pair__output').boundingBox();
    expect(outputBox.x).toBe(codeBox.x);
    expect(outputBox.y).toBeGreaterThan(codeBox.y);
  } finally {
    await mobile.close();
  }
});

for (const transport of ['root','subpath','file']) {
  test(`four reading roles retain complete content on ${transport}`, async ({page}) => {
    for (const locale of ['zh-CN','en']) {
      const urls = await routes(page, locale, transport);
      for (const width of [1440,1181,1180,960,761,760,390]) {
        await page.setViewportSize({width,height:width === 390 ? 844 : 900});
        for (const [role,url] of Object.entries(urls)) {
          await page.goto(url);
          const metrics = await readingMetrics(page);
          expect(metrics.scroll).toBeLessThanOrEqual(metrics.width + 1);
          for (const summary of metrics.summaries) {
            expect(summary.size).toBeGreaterThanOrEqual(15);
            expect(summary.full).toBe(true);
            expect(summary.clamp).toBe('none');
          }
          for (const size of metrics.code) expect(size).toBeGreaterThanOrEqual(14);
          for (const size of metrics.prose) expect(size).toBeGreaterThanOrEqual(15);
        }
      }
      await page.goto(urls.home);
      await expect(page.locator('.cj-home-intro')).toContainText('TextCatalog');
      // The reading-path navigation is distinct from the secondary
      // "other resources" disclosure that reuses the same block class.
      const readingPaths = page.locator('nav.cj-reading-paths');
      await expect(readingPaths.locator('a[href*="concepts/packages/"]')).toHaveCount(0);
      await expect(readingPaths.locator('a[href*="concepts/modules/"]')).toHaveCount(0);
      await expect(readingPaths).toContainText(locale === 'en' ? 'Catalogue and lifetime' : '目录与资源入门');
      if (locale === 'en') await expect(page.locator('.cj-home-intro .cj-content-language')).toHaveAttribute('data-translation-state','fallback');
      await page.goto(urls.package);
      expect(await page.locator('.cj-package-overview').count()).toBe(1);
      await page.goto(urls.api);
      const overloads = page.locator('[data-cjdoc-member][data-member-name="add"]');
      await expect(overloads).toHaveCount(2);
      for (const member of await overloads.all()) await member.evaluate(n => n.open = true);
      await expect(overloads.filter({hasText:'radix'})).toContainText('10');
      const stringOverload = overloads.filter({hasText:'value: String'});
      const guideLink = stringOverload.locator('.cj-usages a[href*="first-catalogue.html"]').first();
      const expectedGuideUrl = manifestSectionUrl(locale, urls.home, urls.guide, 'store-read');
      expect(new URL(await guideLink.getAttribute('href'), page.url()).href).toBe(expectedGuideUrl);
      await guideLink.click();
      expect(page.url()).toBe(expectedGuideUrl);
      const sectionId = decodeURIComponent(new URL(expectedGuideUrl).hash.slice(1));
      await expect(page.locator(`.cj-guide [id="${sectionId}"]`)).toBeVisible();
      await expect(page.locator('.cj-binding > .cj-bindings__state')).toHaveCount(0);
      await expect(page.locator('.cj-binding > .cj-bindings__label').first()).toHaveText(locale === 'en' ? 'Related API:' : '相关 API：');
      await expect(page.locator('.cj-binding a').first()).toHaveAttribute('href', /\/pocketkit\/.+\/index\.html(?:#.*)?$/);
      const introduction = siteManifest.routes.find(item => item.language === locale &&
        !item.symbolId && !item.sectionId && item.href === `html/${locale}/concepts/index.html`);
      expect(introduction).toBeTruthy();
      const introductionUrl = new URL(introduction.href.replace(`html/${locale}/`, ''), urls.home).href;
      const introductionHref = await page.locator('.cj-guide a[href]').evaluateAll(
        (links, target) => links.find(link => link.href === target)?.getAttribute('href'), introductionUrl);
      expect(introductionHref).toBeTruthy();
      await page.locator(`.cj-guide a[href=${JSON.stringify(introductionHref)}]`).first().click();
      await expect(page).toHaveURL(introductionUrl);
      await expect(page.locator('.cj-guide')).toContainText('TextCatalog');
    }
  });
}

test('cold history restores entry-local search filters, not fresh visits or query text', async ({page}) => {
  const urls = await routes(page, 'en', 'root');
  const trigger = page.locator('[data-cjdoc-search-trigger]');
  const kind = page.locator('[data-cjdoc-kind]');
  const pack = page.locator('[data-cjdoc-package]');
  const first = new URL(urls.api);
  first.searchParams.set('theme', 'light');
  await page.goto(first.href);
  await expect(page.locator('dialog')).toHaveCount(0);
  await trigger.click();
  await page.locator('[data-cjdoc-search]').fill('name:find');
  await kind.selectOption('class');
  const packageValue = await pack.locator('option').evaluateAll(
    options => options.find(option => option.value)?.value);
  await pack.selectOption(packageValue);
  await page.keyboard.press('Escape');
  // Theme URL replacement must retain this entry's filters.
  await page.locator('[data-cjdoc-theme-toggle]').click();
  await page.locator('[data-cjdoc-theme-value="dark"]').click();
  await page.keyboard.press('Escape');

  const second = new URL(urls.api);
  second.searchParams.set('visit', 'second');
  await page.goto(second.href);
  await expect(page.locator('dialog')).toHaveCount(0);
  await trigger.click();
  await expect(kind).toHaveValue('');
  await expect(pack).toHaveValue('');
  await kind.selectOption('function');
  await page.keyboard.press('Escape');
  await page.goto(urls.home);
  await page.goBack();
  await trigger.click();
  await expect(kind).toHaveValue('function');
  await expect(pack).toHaveValue('');
  await page.keyboard.press('Escape');
  await page.goBack();
  await trigger.click();
  await expect(kind).toHaveValue('class');
  await expect(pack).toHaveValue(packageValue);
  await expect(page.locator('[data-cjdoc-search]')).toHaveValue('');
  await page.keyboard.press('Escape');
  await page.goto(urls.api);
  await expect(page.locator('dialog')).toHaveCount(0);
  await trigger.click();
  await expect(kind).toHaveValue('');
  await expect(pack).toHaveValue('');
});

test('Chinese display labels preserve raw search kind values and query protocol', async ({page}) => {
  const urls = await routes(page,'zh-CN','file');
  await page.goto(urls.home);
  // Kind and package filters are always present inside the search dialog.
  await page.locator('[data-cjdoc-search-trigger]').click();
  await expect(page.locator('[data-cjdoc-search-dialog]')).toBeVisible();
  await expect(page.locator('[data-cjdoc-kind] option[value="function"]')).toHaveText('函数');
  await expect(page.locator('[data-cjdoc-kind] option[value="concept"]')).toHaveText('指南');
  await page.locator('[data-cjdoc-search]').fill('kind:function add');
  await expect(page.locator('[data-cjdoc-results] .cj-kind').first()).toHaveText('函数');
  await page.locator('[data-cjdoc-kind]').selectOption('function');
  await expect(page.locator('[data-cjdoc-kind]')).toHaveValue('function');
  await expect(page.locator('[data-cjdoc-results] [role="option"]')).not.toHaveCount(0);
});

test('display settings appear only on first open and stay one reusable instance', async ({page}) => {
  await page.setViewportSize({width:1440,height:900});
  const urls = await routes(page,'en','file');
  await page.goto(urls.home);
  const popover = page.locator('[data-cjdoc-theme-popover]');
  const trigger = page.locator('[data-cjdoc-theme-toggle]');
  const label = page.locator('[data-cjdoc-theme-label]');
  const baseline = await page.evaluate(() => ({
    dialogs: document.querySelectorAll('dialog').length,
    inlineScripts: document.querySelectorAll('script:not([src])').length,
  }));
  // A page that never asked for these controls ships neither dialog nor a
  // template standing in for one.
  expect(baseline.dialogs).toBe(0);
  expect(baseline.inlineScripts).toBe(0);
  await expect(popover).toHaveCount(0);
  await expect(page.locator('[data-cjdoc-search-dialog]')).toHaveCount(0);
  await expect(trigger).toHaveAttribute('aria-haspopup','dialog');
  await expect(trigger).toHaveAttribute('aria-expanded','false');
  expect(await trigger.getAttribute('aria-controls')).toBeNull();
  await expect(label).toHaveText('Theme: System');

  await trigger.click();
  await expect(popover).toHaveCount(1);
  await expect(popover).toBeVisible();
  await expect(trigger).toHaveAttribute('aria-controls','cjdoc-theme-popover');
  await expect(trigger).toHaveAttribute('aria-expanded','true');
  await expect(popover).toHaveAttribute('aria-labelledby','cjdoc-settings-title');
  await expect(popover.locator('h2.cj-settings__title')).toHaveText('Display');
  const codeLines = popover.getByRole('group', {name: 'Long code lines', exact: true});
  await expect(codeLines).toHaveAccessibleDescription('Only changes how code is shown, not copied text or expected output.');
  await expect(codeLines.getByRole('button', {name: 'Scroll horizontally', pressed: true})).toBeVisible();
  const longOutput = popover.getByRole('group', {name: 'Long output by default', exact: true});
  await expect(longOutput).toHaveAccessibleDescription('Does not change the whole example.');
  await expect(longOutput.getByRole('button', {name: 'Collapsed', pressed: true})).toBeVisible();
  await expect(popover.getByRole('group', {name: 'Examples by default', exact: true})
    .getByRole('button', {name: 'Expanded', pressed: true})).toBeVisible();
  await expect(popover.locator('[data-cjdoc-theme-value]')).toHaveCount(8);
  await expect(popover.locator('[data-cjdoc-font-value]')).toHaveCount(3);
  await expect(popover.locator('[data-cjdoc-size-value]')).toHaveCount(3);
  await expect(popover.locator('.cj-settings__options--themes')).toHaveCount(1);
  await expect(popover.locator('[data-cjdoc-theme-value="violet"] .cj-settings__swatch'))
    .toHaveAttribute('data-cjdoc-swatch','violet');
  await expect(popover.locator('[data-cjdoc-theme-value="violet"] .cj-settings__swatch'))
    .toHaveAttribute('aria-hidden','true');
  const closeButton = popover.locator('[data-cjdoc-theme-close]');
  await expect(closeButton).toHaveAttribute('aria-label','Close');
  await expect(closeButton.locator('svg.cj-icon path'))
    .toHaveAttribute('d','M6 6l12 12M18 6 6 18');
  await expect(popover.locator('.cj-settings__hint')).toHaveText('System follows your device appearance.');
  await expect(popover.locator('[data-cjdoc-theme-value="system"]')).toHaveAttribute('aria-pressed','true');
  await expect(popover.locator('[data-cjdoc-font-value="system"]')).toHaveAttribute('aria-pressed','true');
  await expect(popover.locator('[data-cjdoc-size-value="m"]')).toHaveAttribute('aria-pressed','true');
  // Creation must not smuggle styling or executable content of its own.
  expect(await popover.evaluate(node => node.getAttribute('style'))).toBeNull();
  expect(await page.evaluate(() => document.querySelectorAll('script:not([src])').length)).toBe(0);

  await popover.locator('[data-cjdoc-theme-value="dark"]').click();
  await expect(page.locator('html')).toHaveAttribute('data-theme','dark');
  await expect(label).toHaveText('Theme: Dark');
  await expect(popover.locator('[data-cjdoc-theme-value="dark"]')).toHaveAttribute('aria-pressed','true');
  await expect(popover.locator('[data-cjdoc-theme-value="system"]')).toHaveAttribute('aria-pressed','false');
  expect(await page.evaluate(() => localStorage.getItem('cjdoc-theme'))).toBe('dark');
  await page.keyboard.press('Escape');
  await expect(popover).toBeHidden();
  await expect(trigger).toBeFocused();
  await expect(trigger).toHaveAttribute('aria-expanded','false');

  // Reopening reuses the same node: no second dialog, no second set of options.
  await trigger.click();
  await expect(popover).toBeVisible();
  expect(await page.evaluate(() => document.querySelectorAll('dialog').length)).toBe(1);
  await expect(popover.locator('[data-cjdoc-theme-value]')).toHaveCount(8);
  await expect(popover.locator('[data-cjdoc-theme-value="dark"]')).toHaveAttribute('aria-pressed','true');
  await expect(label).toHaveText('Theme: Dark');
  await page.keyboard.press('Escape');
  await expect(popover).toBeHidden();

  // The two lazily created dialogs are independent: one request never builds
  // the other, and building one never duplicates it later.
  await expect(page.locator('[data-cjdoc-search-dialog]')).toHaveCount(0);
  await page.locator('[data-cjdoc-search-trigger]').click();
  await expect(page.locator('[data-cjdoc-search-dialog]')).toHaveCount(1);
  await expect(popover).toHaveCount(1);
  await page.keyboard.press('Escape');
  await expect(page.locator('[data-cjdoc-search-dialog]')).toBeHidden();
  await trigger.click();
  await expect(popover).toHaveCount(1);
  await expect(page.locator('[data-cjdoc-search-dialog]')).toHaveCount(1);
  await page.keyboard.press('Escape');

  // The label and pressed state survive a reload without opening anything.
  await page.reload();
  await expect(popover).toHaveCount(0);
  await expect(label).toHaveText('Theme: Dark');
  await expect(page.locator('html')).toHaveAttribute('data-theme','dark');
  await trigger.click();
  await expect(popover.locator('[data-cjdoc-theme-value="dark"]')).toHaveAttribute('aria-pressed','true');
  await page.keyboard.press('Escape');
});

for (const viewport of [{width:1440,height:900},{width:390,height:844}]) {
  test(`search shortcuts transfer modal ownership at ${viewport.width}px`, async ({page}) => {
    await page.setViewportSize(viewport);
    const urls = await routes(page,'en','file');
    for (const key of ['Control+k','Meta+k']) {
      await page.goto(urls.home);
      const settings = page.locator('[data-cjdoc-theme-popover]');
      const search = page.locator('[data-cjdoc-search-dialog]');
      const trigger = page.locator('[data-cjdoc-theme-toggle]');
      await trigger.click();
      await expect(settings).toBeVisible();
      await expect(search).toHaveCount(0);
      await page.keyboard.press(key);
      await expect(settings).toBeHidden();
      await expect(trigger).toHaveAttribute('aria-expanded','false');
      await expect(search).toBeVisible();
      await expect(page.locator('dialog:modal')).toHaveCount(1);
      await expect(page.locator('[data-cjdoc-search]')).toBeFocused();
      await page.keyboard.press('Escape');
      await expect(trigger).toBeFocused();
      await trigger.click();
      await page.keyboard.press(key);
      await expect(settings).toBeHidden();
      await expect(settings).toHaveCount(1);
      await expect(search).toHaveCount(1);
      await expect(page.locator('dialog:modal')).toHaveCount(1);
      await expect(page.locator('[data-cjdoc-search]')).toBeFocused();
    }
    if (viewport.width < 760) {
      await page.keyboard.press('Escape');
      await page.locator('[data-cjdoc-menu]').click();
      await expect(page.locator('html')).toHaveAttribute('data-cj-drawer','open');
      await page.keyboard.press('Control+k');
      await expect(page.locator('html')).not.toHaveAttribute('data-cj-drawer','open');
      await expect(page.locator('dialog:modal')).toHaveCount(1);
      await expect(page.locator('[data-cjdoc-search]')).toBeFocused();
    }
  });
}

test('Chinese settings copy and the modal sheet stay intact on the first open', async ({page}) => {
  await page.setViewportSize({width:390,height:844});
  const urls = await routes(page,'zh-CN','file');
  await page.goto(urls.home);
  const popover = page.locator('[data-cjdoc-theme-popover]');
  const trigger = page.locator('[data-cjdoc-theme-toggle]');
  await expect(popover).toHaveCount(0);
  await expect(page.locator('[data-cjdoc-theme-label]')).toHaveText('主题：跟随系统');
  await trigger.click();
  await expect(popover).toBeVisible();
  await expect(popover.locator('#cjdoc-settings-title')).toHaveText('显示');
  const codeLines = popover.getByRole('group', {name: '代码块长行', exact: true});
  await expect(codeLines).toHaveAccessibleDescription('只改变代码显示，不改变复制内容或预期输出。');
  await codeLines.getByRole('button', {name: '自动换行', exact: true}).click();
  await expect(codeLines.getByRole('button', {name: '自动换行', pressed: true})).toBeVisible();
  const longOutput = popover.getByRole('group', {name: '长输出默认状态', exact: true});
  await expect(longOutput).toHaveAccessibleDescription('不改变整个示例的状态。');
  await longOutput.getByRole('button', {name: '展开', exact: true}).click();
  await expect(longOutput.getByRole('button', {name: '展开', pressed: true})).toBeVisible();
  await expect(popover.getByRole('button', {name: '恢复默认设置', exact: true})).toBeVisible();
  await expect(popover.locator('[data-cjdoc-theme-value="paper"] span').last()).toHaveText('纸色');
  await expect(popover.locator('[data-cjdoc-theme-value="system"] span').last()).toHaveText('跟随系统');
  await expect(popover.locator('[data-cjdoc-font-value="mono-ui"] span').last()).toHaveText('等宽');
  await expect(popover.locator('[data-cjdoc-size-value="l"]')).toHaveText('L');
  await expect(popover.locator('[data-cjdoc-theme-close]')).toHaveAttribute('aria-label','关闭');
  await expect(popover.locator('.cj-settings__hint')).toHaveText('跟随系统会采用设备的外观设置。');
  // On a phone viewport this dialog is a modal bottom sheet: focus stays inside
  // and Escape returns it to the trigger.
  expect(await popover.evaluate(element => element.matches(':modal'))).toBe(true);
  await popover.locator('[data-cjdoc-size-value="l"]').click();
  await expect(page.locator('html')).toHaveAttribute('data-cj-size','l');
  await expect(page.locator('[data-cjdoc-theme-label]')).toHaveText('主题：跟随系统');
  const buttons = popover.locator('button');
  await buttons.last().focus();
  await page.keyboard.press('Shift+Tab');
  expect(await page.evaluate(() => document.activeElement !== document.body &&
    document.activeElement !== document.documentElement)).toBe(true);
  await page.keyboard.press('Escape');
  await expect(popover).toBeHidden();
  await expect(trigger).toBeFocused();
});

test('reader preferences: reset keeps search and navigation state on a short screen', async ({page}) => {
  await page.setViewportSize({width: 390, height: 568});
  await page.emulateMedia({colorScheme: 'light'});
  const {home} = await routes(page, 'en', 'root');
  await page.goto(new URL('?theme=dark&keep=1#packages', home).href);
  const root = page.locator('html');
  await expect(root).toHaveAttribute('data-theme', 'dark');
  await page.locator('[data-cjdoc-search-trigger]').click();
  await page.locator('[data-cjdoc-kind]').selectOption('function');
  const searchState = () => page.evaluate(() => history.state?.cjdocSearchFilters);
  const filters = await searchState();
  expect(filters).toMatchObject({kind: 'function'});
  await page.keyboard.press('Escape');
  await page.evaluate(() => {
    localStorage.setItem('other-preference', 'keep-local');
    sessionStorage.setItem('other-state', 'keep-session');
  });

  const trigger = page.locator('[data-cjdoc-theme-toggle]');
  const dialog = page.getByRole('dialog', {name: 'Display'});
  const option = (name, choice) => dialog.getByRole('group', {name, exact: true})
    .getByRole('button', {name: choice, exact: true});
  const reset = dialog.getByRole('button', {name: 'Reset display settings', exact: true});
  const close = dialog.getByRole('button', {name: 'Close', exact: true});
  await trigger.click();
  await option('Font', 'Serif').click();
  await option('Text size', 'L').click();
  await expect(root).toHaveAttribute('data-cj-size', 'l');
  const before = await close.boundingBox();
  for (const [name, choice, change] of [
    ['Long code lines', 'Scroll horizontally', false],
    ['Long code lines', 'Wrap', true],
    ['Examples by default', 'Expanded', false],
    ['Examples by default', 'Collapsed', true],
    ['Long output by default', 'Expanded', true],
    ['Long output by default', 'Collapsed', false],
    ['API notices', 'Show separately', false],
    ['API notices', 'Group by type', true],
  ]) {
    const button = option(name, choice);
    // A preference can reflow the document; moving focus within the panel cannot.
    const backgroundScroll = await page.evaluate(() => window.scrollY);
    await page.keyboard.press('Tab');
    await expect(button).toBeFocused();
    expect(await page.evaluate(() => window.scrollY)).toBe(backgroundScroll);
    if (change) {
      await page.keyboard.press('Space');
      await expect(button).toHaveAttribute('aria-pressed', 'true');
    }
  }
  const backgroundScroll = await page.evaluate(() => window.scrollY);
  await page.keyboard.press('Tab');
  await expect(reset).toBeFocused();
  await expect(reset).toBeInViewport();
  const panel = await dialog.evaluate(node => ({
    scrollTop: node.scrollTop, horizontal: node.scrollWidth - node.clientWidth, pageScroll: window.scrollY,
  }));
  expect(panel.scrollTop).toBeGreaterThan(0);
  expect(panel.horizontal).toBe(0);
  expect(panel.pageScroll).toBe(backgroundScroll);
  expect((await close.boundingBox()).y).toBeCloseTo(before.y, 0);

  await page.keyboard.press('Enter');
  await expect(reset).toBeFocused();
  await expect(dialog.getByRole('status')).toHaveText('Display settings reset.');
  for (const [name, choice] of [
    ['Theme', 'System'], ['Font', 'System'], ['Text size', 'M'], ['Long code lines', 'Scroll horizontally'],
    ['Examples by default', 'Expanded'], ['Long output by default', 'Collapsed'],
    ['API notices', 'Show separately'],
  ]) {
    await expect(option(name, choice)).toHaveAttribute('aria-pressed', 'true');
  }
  for (const attribute of ['data-theme', 'data-cj-font', 'data-cj-size', 'data-cj-code-lines']) {
    expect(await root.getAttribute(attribute)).toBeNull();
  }
  await expect(dialog).toBeVisible();
  await expect(page.locator('[data-cjdoc-theme-label]')).toHaveText('Theme: System');
  expect(new URL(page.url()).searchParams.get('theme')).toBe('system');
  expect(new URL(page.url()).searchParams.get('keep')).toBe('1');
  expect(new URL(page.url()).hash).toBe('#packages');
  expect(await searchState()).toEqual(filters);
  expect(await page.evaluate(() => [
    localStorage.getItem('cjdoc-reader'),
    localStorage.getItem('other-preference'),
    sessionStorage.getItem('other-state'),
  ])).toEqual([null, 'keep-local', 'keep-session']);

  await option('Text size', 'M').click();
  await expect(dialog.getByRole('status')).toBeEmpty();
  await page.keyboard.press('Escape');
  await expect(trigger).toBeFocused();
  await page.reload();
  await expect(root).not.toHaveAttribute('data-theme', 'dark');
  await expect(page.locator('[data-cjdoc-theme-label]')).toHaveText('Theme: System');
  await trigger.press('Enter');
  await page.keyboard.press('Shift+Tab');
  await expect(close).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(trigger).toBeFocused();
  await trigger.press('Enter');
  await page.keyboard.press('Control+k');
  await expect(dialog).toBeHidden();
  await expect(page.locator('[data-cjdoc-search]')).toBeFocused();
});

test('reader preferences: wrap follows the language switch and paints before search.js', async ({page}) => {
  const {home, guide} = await routes(page, 'zh-CN', 'root');
  await page.goto(home);
  await page.locator('[data-cjdoc-theme-toggle]').click();
  await page.getByRole('group', {name: '代码块长行', exact: true})
    .getByRole('button', {name: '自动换行', exact: true}).click();
  await page.keyboard.press('Escape');
  await expect(page.locator('.cj-home-intro pre').first()).toHaveCSS('white-space', 'pre-wrap');
  await page.locator('.cj-home-intro').getByRole('link', {name: '调用 PocketKit', exact: true}).click();
  await expect(page).toHaveURL(guide);
  await expect(page.locator('.cj-guide pre').first()).toHaveCSS('white-space', 'pre-wrap');
  await page.locator('.cj-lang-toggle__current').click();
  await page.locator('.cj-lang-toggle a[hreflang="en"]').click();
  await expect(page.locator('html')).toHaveAttribute('lang', 'en');
  const code = page.locator('.cj-guide pre').first();
  await expect(code).toHaveCSS('white-space', 'pre-wrap');

  await page.route('**/search.js', route => route.abort());
  await page.reload();
  await expect(code).toHaveCSS('white-space', 'pre-wrap');
  await expect(page.locator('dialog')).toHaveCount(0);
});

test('Example disclosure preference applies across pages without saving individual toggles', async ({page}) => {
  await page.setViewportSize({width:390,height:844});
  const {home} = await routes(page, 'zh-CN', 'root');
  await page.goto(home);
  const sample = page.locator('.cj-home-intro .cj-example-pair--prose');
  const summary = sample.locator('.cj-example__summary');
  const output = sample.locator('.cj-example-pair__output pre code');
  await expect(output).toHaveText('hello');
  await summary.press('Enter');
  await expect(summary).toBeVisible();
  await expect(output).toBeHidden();
  await summary.press('Enter');
  await expect(output).toBeVisible();

  const settings = page.getByRole('group', {name: '示例默认状态'});
  const longOutputs = page.getByRole('group', {name: '长输出默认状态'});
  const trigger = page.locator('[data-cjdoc-theme-toggle]');
  await trigger.click();
  await longOutputs.getByRole('button', {name: '展开', exact: true}).click();
  await expect(sample.locator('.cj-example-pair__disclosure')).toHaveCount(0);
  await expect(settings.getByRole('button', {name: '展开'})).toHaveAttribute('aria-pressed', 'true');
  await settings.getByRole('button', {name: '折叠'}).click();
  await page.keyboard.press('Escape');
  await expect(output).toBeHidden();

  await page.locator('.cj-home-intro').getByRole('link', {name: '编写文档注释', exact: true}).click();
  const comparison = page.locator('.cj-guide .cj-example-pair--side-by-side');
  await expect(comparison.locator('.cj-example__summary')).toBeVisible();
  await expect(comparison.locator('.cj-example-pair__output')).toBeHidden();
  await authoringBinding(page, 'window(Int64, Int64)').click();
  const cases = page.locator('.cj-example');
  const caseOutputs = cases.locator('.cj-example-pair__output');
  await expect(cases.locator('.cj-example__summary:visible')).toHaveCount(4);
  await expect(caseOutputs.filter({visible: true})).toHaveCount(0);
  await cases.first().locator('.cj-example__summary').press('Enter');
  await expect(caseOutputs.first()).toBeVisible();
  await expect(caseOutputs.filter({visible: true})).toHaveCount(1);
  await page.reload();
  await expect(caseOutputs.filter({visible: true})).toHaveCount(0);

  await trigger.click();
  await expect(settings.getByRole('button', {name: '折叠'})).toHaveAttribute('aria-pressed', 'true');
  await settings.getByRole('button', {name: '展开'}).click();
  await page.keyboard.press('Escape');
  await expect(caseOutputs.filter({visible: true})).toHaveCount(4);
  await trigger.click();
  await longOutputs.getByRole('button', {name: '折叠', exact: true}).click();
  await page.keyboard.press('Escape');
  await page.reload();
  await expect(caseOutputs.filter({visible: true})).toHaveCount(4);
  await page.goBack();
  await authoringBinding(page, 'requireFirstText(TextCatalog)').click();
  const quiet = page.locator('.cj-example').filter({hasText: '不打印也可以核对输出'});
  await expect(quiet.getByText('预期无标准输出。', {exact: true})).toBeVisible();
  await expect(quiet.locator('.cj-example-pair__disclosure')).toHaveCount(0);
});

test('mobile member filters yield to the first complete signature and retain active criteria', async ({page}) => {
  await page.setViewportSize({width:390,height:844});
  for (const locale of ['zh-CN','en']) {
    const urls = await routes(page,locale,'file');
    await page.goto(urls.api);
    const toggle = page.locator('[data-cjdoc-member-filter-toggle]');
    await expect(toggle).toHaveAttribute('aria-expanded','false');
    await expect(page.locator('[data-cjdoc-member-filter]')).toBeHidden();
    const toolbar = await page.locator('.cj-members__toolbar').boundingBox();
    expect(toolbar.height).toBeLessThanOrEqual(44);
    if (locale === 'zh-CN') {
      const first = await page.locator('[data-cjdoc-member] .cj-signature-inline').first().boundingBox();
      expect(first.y + first.height).toBeLessThan(844);
    }
    await toggle.click();
    await expect(toggle).toHaveAttribute('aria-expanded','true');
    await page.locator('[data-cjdoc-member-filter]').fill('radix');
    await expect(page.locator('[data-cjdoc-member]:visible')).toHaveCount(1);
    await expect(toggle).toContainText('(1)');
    await toggle.click();
    await expect(page.locator('[data-cjdoc-member-filter]')).toBeHidden();
    await expect(page.locator('[data-cjdoc-member]:visible')).toHaveCount(1);
    await toggle.click();
    await expect(page.locator('[data-cjdoc-member-filter]')).toHaveValue('radix');
    await page.setViewportSize({width:960,height:900});
    await expect(toggle).toBeHidden();
    await expect(page.locator('[data-cjdoc-member-filter]')).toBeVisible();
    await page.setViewportSize({width:390,height:844});
  }
});

test('all theme presets keep normal text contrast and use offline font fallbacks', async ({page}, testInfo) => {
  test.setTimeout(90000);
  const observations = [];
  for (const locale of ['zh-CN','en']) {
    const urls = await routes(page, locale, 'file');
    for (const [role,url] of Object.entries(urls)) {
      await page.goto(url);
      // The settings dialog stays open across theme choices, so open it once.
      await page.locator('[data-cjdoc-theme-toggle]').click();
      for (const theme of ['system','light','dark','paper','ocean','forest','terminal','violet']) {
        await page.locator(`[data-cjdoc-theme-value="${theme}"]`).click();
        await page.evaluate(() => {
          for (const animation of document.getAnimations()) {
            if (animation.effect.getTiming().iterations !== Infinity) animation.finish();
          }
        });
        const result = await page.evaluate(() => {
          const rgb = s => (s.match(/[\d.]+/g)||[]).map(Number);
          const lum = a => a.slice(0,3).map(c=>c/255).map(c=>c<=.04045?c/12.92:((c+.055)/1.055)**2.4)
            .reduce((s,c,i)=>s+c*[.2126,.7152,.0722][i],0);
          const failures=[]; let minimum=100, count=0;
          for (const el of document.querySelectorAll('body *')) {
            if (!el.checkVisibility({checkOpacity:true,checkVisibilityCSS:true}) || el.closest('svg,.cj-sr-only,.cj-skip-link')) continue;
            if (![...el.childNodes].some(n=>n.nodeType===3 && n.textContent.trim())) continue;
            const style = getComputedStyle(el);
            if (parseFloat(style.fontSize)>=24) continue;
            let bg=el, color;
            while (bg) { color=rgb(getComputedStyle(bg).backgroundColor); if ((color[3]??1)>0) break; bg=bg.parentElement; }
            if (!bg) continue;
            const a=lum(rgb(style.color)), b=lum(color), ratio=(Math.max(a,b)+.05)/(Math.min(a,b)+.05);
            minimum=Math.min(minimum,ratio); count++;
            if (ratio<4.5) failures.push({text:el.textContent.slice(0,60),ratio});
          }
          return {minimum,count,failures};
        });
        observations.push({locale,role,theme,...result});
        expect(result.failures, `${locale}/${role}/${theme}`).toEqual([]);
      }
      await page.keyboard.press('Escape');
      const session = await page.context().newCDPSession(page);
      await session.send('DOM.enable'); await session.send('CSS.enable');
      const {root} = await session.send('DOM.getDocument');
      for (const selector of ['h1:visible','.cj-prose > p:visible','pre code:visible','.cj-member__description:visible']) {
        const locator = page.locator(selector).first();
        if (!await locator.count()) continue;
        const plainSelector = selector.replace(':visible', '');
        // Query the exact visible occurrence, not a collapsed example with no glyphs.
        const index = await locator.evaluate((node, selector) =>
          [...document.querySelectorAll(selector)].indexOf(node), plainSelector);
        const {nodeIds} = await session.send('DOM.querySelectorAll',{nodeId:root.nodeId,selector:plainSelector});
        const nodeId = nodeIds[index];
        if (nodeId) {
          const {fonts} = await session.send('CSS.getPlatformFontsForNode',{nodeId});
          observations.push({locale,role,selector,fonts});
          expect(fonts.length).toBeGreaterThan(0);
          expect(fonts.every(font=>!font.isCustomFont)).toBe(true);
        }
      }
      await session.detach();
    }
  }
  await testInfo.attach('contrast-and-platform-fonts',{body:JSON.stringify(observations,null,2),contentType:'application/json'});
});

test('native details, guide return and print remain usable without JavaScript at the 200 percent reflow viewport', async ({browser}) => {
  const context = await browser.newContext({javaScriptEnabled:false,viewport:{width:720,height:450}});
  const page = await context.newPage();
  const urls = await routes(page,'zh-CN','file');
  await page.goto(urls.api);
  const member=page.locator('[data-cjdoc-member][data-member-name="add"]').first();
  await member.locator('summary').click();
  await expect(member).toHaveAttribute('open','');
  await expect(member.locator('.cj-member__body')).toBeVisible();
  await expect(page.locator('.cj-member-actions .cj-member-actions__item--standalone').first()).toBeVisible();
  const metrics=await readingMetrics(page); expect(metrics.scroll).toBeLessThanOrEqual(metrics.width+1);
  await page.emulateMedia({media:'print'});
  await expect(page.locator('.cj-sidebar')).toBeHidden();
  await expect(page.locator('.cj-member__body').first()).toBeVisible();
  await page.goto(urls.guide);
  await expect(page.locator('.cj-guide')).toContainText('String');
  await context.close();
});
