import {test, expect} from '@playwright/test';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import path from 'node:path';

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
  const pkg = new URL(await page.locator('.cj-package-index a').first().getAttribute('href'), home).href;
  await page.goto(pkg);
  const api = new URL(await page.locator('.cj-decl-table__link').filter({hasText:'TextCatalog'}).first().getAttribute('href'), pkg).href;
  return {home, package:pkg, api, guide:new URL('concepts/guides/first-catalogue.html',home).href};
}

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
      await expect(page.locator('.cj-binding a').first()).toHaveAttribute('href', /symbols\/.*\.html(?:#.*)?$/);
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
  await expect(popover.locator('.cj-settings__group')).toHaveCount(3);
  await expect(popover.locator('.cj-settings__legend')).toHaveText(['Theme','Font','Text size']);
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
  await expect(popover.locator('.cj-settings__legend')).toHaveText(['主题','字体','字号']);
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
      for (const selector of ['h1','.cj-prose > p','pre code','.cj-member__description']) {
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
