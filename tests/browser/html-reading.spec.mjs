import {test, expect} from '@playwright/test';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import path from 'node:path';

const fixture = process.env.CJDOC_READING_FIXTURE;
test.skip(!fixture, 'CJDOC_READING_FIXTURE must point to a generated bilingual PocketKit site');
let server, origin;
test.beforeAll(async () => {
  if (!fixture) return;
  server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url, 'http://localhost');
      const relative = decodeURIComponent(url.pathname).replace(/^\/docs\//, '/');
      const target = path.resolve(fixture, '.' + relative);
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

async function routes(page, locale, transport) {
  const home = transport === 'file'
    ? pathToFileURL(path.resolve(fixture, locale, 'index.html')).href
    : `${origin}${transport === 'subpath' ? '/docs' : ''}/${locale}/index.html`;
  await page.goto(home);
  const pkg = new URL(await page.locator('.package-index a').first().getAttribute('href'), home).href;
  await page.goto(pkg);
  const api = new URL(await page.locator('.declaration-row-link').filter({hasText:'TextCatalog'}).first().getAttribute('href'), pkg).href;
  return {home, package:pkg, api, guide:new URL('concepts/guides/first-catalogue.html',home).href};
}

async function readingMetrics(page) {
  return page.evaluate(() => {
    const visible = selector => [...document.querySelectorAll(selector)].filter(n => n.checkVisibility({checkVisibilityCSS:true}));
    return {
      width:document.documentElement.clientWidth, scroll:document.documentElement.scrollWidth,
      headings:visible('main h1').length,
      summaries:visible('.declaration-description,.member-summary-description').map(n => ({
        size:parseFloat(getComputedStyle(n).fontSize), full:n.scrollHeight <= n.clientHeight + 1,
        clamp:getComputedStyle(n).webkitLineClamp,
      })),
      code:visible('pre code,.declaration-signature').map(n => parseFloat(getComputedStyle(n).fontSize)),
      prose:visible('.prose > p').map(n => parseFloat(getComputedStyle(n).fontSize)),
    };
  });
}

for (const transport of ['root','subpath','file']) {
  test(`four reading roles retain complete content on ${transport}`, async ({page}) => {
    for (const locale of ['zh-CN','en']) {
      const urls = await routes(page, locale, transport);
      for (const width of [1440,1181,1180,960,761,760,390]) {
        await page.setViewportSize({width,height:width === 390 ? 844 : 900});
        for (const [role,url] of Object.entries(urls)) {
          await page.goto(url);
          const metrics = await readingMetrics(page);
          expect(metrics.headings, `${locale}/${role}/${width}`).toBe(1);
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
      await expect(page.locator('.home-introduction')).toContainText('TextCatalog');
      const homeOrder = await page.evaluate(() => ({
        paths:document.querySelector('.reading-paths').getBoundingClientRect().top,
        boundary:document.querySelector('.home-introduction h2[id^="standalone--doc-"]').getBoundingClientRect().top,
      }));
      expect(homeOrder.paths).toBeLessThan(homeOrder.boundary);
      await expect(page.locator('.reading-paths a[href*="concepts/packages/"]')).toHaveCount(0);
      await expect(page.locator('.reading-paths a[href*="concepts/modules/"]')).toHaveCount(0);
      await expect(page.locator('.reading-paths')).toContainText(locale === 'en' ? 'Catalogue and lifetime' : '目录与资源入门');
      if (locale === 'en') await expect(page.locator('.home-introduction .content-language')).toHaveAttribute('data-translation-state','fallback');
      await page.goto(urls.package);
      expect(await page.locator('.package-overview').count()).toBe(1);
      await page.goto(urls.api);
      await expect(page.locator('.api-declaration-heading,.api-overview-heading,.member-display-name')).toHaveCount(0);
      await expect(page.locator('.sidebar-context')).toHaveCount(0);
      for (const group of await page.locator('.member-group-heading').all()) {
        const title = await group.locator('h2').boundingBox();
        const count = await group.locator('.member-group-count').boundingBox();
        expect(Math.abs(title.y-count.y)).toBeLessThan(12);
      }
      const overloads = page.locator('[data-cjdoc-member][data-member-name="add"]');
      await expect(overloads).toHaveCount(2);
      for (const member of await overloads.all()) await member.evaluate(n => n.open = true);
      await expect(overloads.filter({hasText:'radix'})).toContainText('10');
      const stringOverload = overloads.filter({hasText:'value: String'});
      const guideLink = stringOverload.locator('.api-usages a[href*="first-catalogue.html"]').first();
      await expect(guideLink).toHaveAttribute('href', /first-catalogue\.html#standalone--doc-/);
      await guideLink.click();
      expect(new URL(page.url()).hash).toMatch(/^#standalone--doc-/);
      await expect(page.locator('.guide-content h2').first()).toHaveAttribute('id', /^standalone--doc-/);
      await expect(page.locator('.guide-content h3')).toHaveCount(0);
      await expect(page.locator('.inline-binding > .binding-state')).toHaveCount(0);
      await expect(page.locator('.inline-binding > .related-api-label').first()).toHaveText(locale === 'en' ? 'Related API:' : '相关 API：');
      await expect(page.locator('.inline-binding a').first()).toHaveAttribute('href', /symbols\/.*\.html(?:#.*)?$/);
    }
  });
}

test('Chinese display labels preserve raw search kind values and query protocol', async ({page}) => {
  const urls = await routes(page,'zh-CN','file');
  await page.goto(urls.home);
  await page.locator('[data-cjdoc-filter-toggle]').click();
  await expect(page.locator('[data-cjdoc-kind] option[value="function"]')).toHaveText('函数');
  await expect(page.locator('[data-cjdoc-kind] option[value="concept"]')).toHaveText('指南');
  await page.locator('[data-cjdoc-search]').fill('kind:function add');
  await expect(page.locator('[data-cjdoc-results] .search-kind').first()).toHaveText('函数');
  await page.locator('[data-cjdoc-kind]').selectOption('function');
  await expect(page.locator('[data-cjdoc-kind]')).toHaveValue('function');
  await expect(page.locator('[data-cjdoc-filter-toggle]')).toContainText('(1)');
});

test('mobile member filters yield to the first complete signature and retain active criteria', async ({page}) => {
  await page.setViewportSize({width:390,height:844});
  for (const locale of ['zh-CN','en']) {
    const urls = await routes(page,locale,'file');
    await page.goto(urls.api);
    const toggle = page.locator('[data-cjdoc-member-filter-toggle]');
    await expect(toggle).toHaveAttribute('aria-expanded','false');
    await expect(page.locator('[data-cjdoc-member-filter]')).toBeHidden();
    const toolbar = await page.locator('.member-browser-toolbar').boundingBox();
    expect(toolbar.height).toBeLessThanOrEqual(44);
    if (locale === 'zh-CN') {
      const first = await page.locator('[data-cjdoc-member] .declaration-signature').first().boundingBox();
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
      for (const theme of ['system','light','dark','paper','ocean','forest','terminal','violet']) {
        await page.locator('[data-cjdoc-theme-toggle]').click();
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
            if (!el.checkVisibility({checkOpacity:true,checkVisibilityCSS:true}) || el.closest('svg,.sr-only,.skip-link')) continue;
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
      const session = await page.context().newCDPSession(page);
      await session.send('DOM.enable'); await session.send('CSS.enable');
      const {root} = await session.send('DOM.getDocument');
      for (const selector of ['h1','.prose > p','pre code','.member-summary-description']) {
        const {nodeId} = await session.send('DOM.querySelector',{nodeId:root.nodeId,selector});
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
  await expect(member.locator('.member-detail-body')).toBeVisible();
  await expect(page.locator('.member-detail-actions a').first()).toBeVisible();
  const metrics=await readingMetrics(page); expect(metrics.scroll).toBeLessThanOrEqual(metrics.width+1);
  await page.emulateMedia({media:'print'});
  await expect(page.locator('.docs-sidebar')).toBeHidden();
  await expect(page.locator('.member-detail-body').first()).toBeVisible();
  await page.goto(urls.guide);
  await expect(page.locator('.guide-content')).toContainText('String');
  await context.close();
});
