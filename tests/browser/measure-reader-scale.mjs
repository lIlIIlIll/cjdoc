#!/usr/bin/env node
/** Native-site benchmark: --site DIR --manifest JSON --output DIR --label baseline|after
 * Optional: --samples 20 --transports root,subpath,file --screenshots --locale en.
 * Timings describe scripted tasks, not a human usability study. No indexes are fabricated.
 */
import { createServer } from 'node:http';
import { execFileSync } from 'node:child_process';
import { readFile, mkdir, realpath, stat } from 'node:fs/promises';
import { writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { chromium, playwrightVersion, distribution, entryIndex, installMetrics, pageMetrics,
  resourceSizes, screenshot, sha256, timedQuery, typeEntry } from './reader-scale-metrics.mjs';
import { anchorFor, instrumentedPage, memberTasks, overloadTasks, queryTasks } from './reader-scale-tasks.mjs';

async function fontIdentities(report) {
  const families = new Set();
  const visit = value => {
    if (!value || typeof value !== 'object') return;
    if (Array.isArray(value.fonts)) for (const font of value.fonts) if (!font.custom) families.add(font.family);
    for (const child of Object.values(value)) if (child && typeof child === 'object') visit(child);
  };
  visit(report);
  const identities = [];
  for (const family of [...families].sort()) {
    try {
      const file = execFileSync('fc-match', ['--format', '%{file}', '--', family], { encoding: 'utf8', timeout: 5000 }).trim();
      identities.push({ family, file: path.basename(file), sha256: sha256(await readFile(file)), status: 'measured' });
    } catch (_) {
      identities.push({ family, status: 'unavailable', reason: 'fontconfig file identity is unavailable on this platform' });
    }
  }
  return identities;
}

function options() {
  const values = { samples: 20, transports: 'root,subpath,file', screenshots: false, locale: null };
  for (let i = 2; i < process.argv.length; i++) {
    const key = process.argv[i].replace(/^--/, '');
    if (key === 'screenshots') { values.screenshots = true; continue; }
    if (!['site', 'manifest', 'output', 'label', 'samples', 'transports', 'locale'].includes(key) || !process.argv[i + 1]) throw new Error('Invalid option: ' + process.argv[i]);
    values[key] = process.argv[++i];
  }
  for (const key of ['site', 'manifest', 'output', 'label']) if (!values[key]) throw new Error('Missing --' + key);
  if (!['baseline', 'after'].includes(values.label)) throw new Error('label must be baseline or after');
  values.samples = Number(values.samples);
  if (!Number.isInteger(values.samples) || values.samples < 2 || values.samples > 100) throw new Error('samples must be in 2..100');
  values.transports = values.transports.split(',');
  if (values.transports.some(value => !['root', 'subpath', 'file'].includes(value))) throw new Error('Unsupported transport');
  return values;
}

async function serve(site) {
  const root = await realpath(site);
  const server = createServer(async (request, response) => {
    try {
      let relative = decodeURIComponent(new URL(request.url, 'http://example.test').pathname);
      if (relative.startsWith('/reader-subpath/')) relative = relative.slice('/reader-subpath'.length);
      if (relative.endsWith('/')) relative += 'index.html';
      const candidate = await realpath(path.resolve(root, '.' + relative));
      if (!candidate.startsWith(root + path.sep) || !(await stat(candidate)).isFile()) throw new Error('outside native site');
      const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8' };
      response.writeHead(200, { 'Content-Type': types[path.extname(candidate)] || 'application/octet-stream', 'Cache-Control': 'public, max-age=3600' });
      response.end(await readFile(candidate));
    } catch (_) { response.writeHead(404); response.end('Not found'); }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, 'localhost', resolve); });
  return { server, origin: 'http://localhost:' + server.address().port };
}

const viewports = [
  { id: 'desktop', width: 1440, height: 900 }, { id: 'split', width: 960, height: 900 },
  { id: 'mobile', width: 390, height: 844 }, { id: 'bp760', width: 760, height: 900 },
  { id: 'bp761', width: 761, height: 900 }, { id: 'bp1180', width: 1180, height: 900 },
  { id: 'bp1181', width: 1181, height: 900 },
  { id: 'zoom200', width: 720, height: 450, deviceScaleFactor: 2 },
];

async function loadingTask(context, index, base) {
  const { page, client } = await instrumentedPage(context, new URL('index.html', base).href, true);
  try {
    const firstQuery = index.entries.find(entry => entry.kind === 'function');
    if (!firstQuery) throw new Error('Native corpus has no function entries');
    const coldProbe = await timedQuery(page, firstQuery.qualifiedName);
    const cold = { firstInteractiveProbeMs: await page.evaluate(() => performance.now()),
      probeDeliveredResults: coldProbe.displayed > 0, ...await pageMetrics(page, client) };
    await client.send('Network.setCacheDisabled', { cacheDisabled: false });
    await page.reload({ waitUntil: 'load' }); // Prime an enabled browser cache explicitly.
    await page.reload({ waitUntil: 'load' });
    const warmProbe = await timedQuery(page, firstQuery.qualifiedName);
    const warm = { firstInteractiveProbeMs: await page.evaluate(() => performance.now()),
      probeDeliveredResults: warmProbe.displayed > 0, ...await pageMetrics(page, client) };
    const bytes = await readFile(path.join(config.site, 'search-index.json'), 'utf8');
    const parse = await page.evaluate(text => {
      const samples = [];
      for (let iteration = 0; iteration < 5; iteration++) {
        const started = performance.now();
        const parsed = JSON.parse(text);
        samples.push(performance.now() - started);
        if (!Array.isArray(parsed.entries)) throw new Error('Invalid native companion index');
      }
      return samples;
    }, bytes);
    return { cold, warm, jsonParse: distribution(parse),
      semantics: 'cold disables browser cache; warm follows an enabled-cache priming reload; OS cache is not controlled; companion JSON parse is isolated from actual JS-index load' };
  } finally { await page.close(); }
}

async function visualTasks(browser, index, manifest, base, output, locale, records) {
  const targets = (manifest.visuals || []).map((spec, i) => ({
    id: 'authored-' + i, entry: index.entries.find(entry => entry.qualifiedName === spec.qualifiedName) }));
  const member = manifest.members.find(item => item.ordinal === 500);
  if (member) {
    const owner = typeEntry(index, member.owner);
    const last = index.entries.find(entry => entry.qualifiedName === member.qualifiedName);
    targets.unshift({ id: 'member500', entry: owner, anchor: anchorFor(last) });
  }
  const over = manifest.overloads.find(item => item.count === 16);
  if (over) {
    const owner = typeEntry(index, over.owner);
    const last = index.entries.find(entry => entry.qualifiedName === over.targets.at(-1).qualifiedName &&
      JSON.stringify(entry.parameterTypes) === JSON.stringify(over.targets.at(-1).parameterTypes));
    targets.unshift({ id: 'overload16', entry: owner, anchor: anchorFor(last) });
  }
  for (const viewport of viewports) for (const theme of ['light', 'dark']) {
    const context = await browser.newContext({ viewport: { width: viewport.width, height: viewport.height },
      deviceScaleFactor: viewport.deviceScaleFactor || 1, locale: 'en-US', colorScheme: theme,
      reducedMotion: 'reduce' });
    await installMetrics(context);
    try {
      for (const target of targets) {
        if (!target.entry) { records.push({ target: target.id, viewport: viewport.id, theme, pass: false, reason: 'native target identity absent' }); continue; }
        const url = new URL(target.entry.href, base);
        url.searchParams.set('theme', theme);
        if (target.anchor) url.hash = target.anchor;
        const { page, client } = await instrumentedPage(context, url.href);
        try {
          if (target.anchor) await page.waitForFunction(id => document.getElementById(id)?.open, target.anchor);
          const metrics = await pageMetrics(page, client);
          const focus = await page.evaluate(() => ({
            positiveTabindex: document.querySelectorAll('[tabindex]:not([tabindex="0"]):not([tabindex="-1"])').length,
            mainLandmark: document.querySelectorAll('main').length,
            headingCount: document.querySelectorAll('h1').length,
            focusedTag: document.activeElement?.tagName,
          }));
          await page.keyboard.press('Tab');
          const keyboardFocus = await page.evaluate(() => ({ tag: document.activeElement?.tagName,
            focusVisible: document.activeElement?.matches(':focus-visible') || false,
            label: document.activeElement?.getAttribute('aria-label') || document.activeElement?.textContent?.trim().slice(0, 200) || '' }));
          const image = await screenshot(page, output, [locale, viewport.id, theme, target.id].join('-'));
          records.push({ target: target.id, viewport: viewport.id, theme, locale, metrics, focus, keyboardFocus,
            zoom: viewport.id === 'zoom200' ? { percent: 200, physicalViewport: { width: 1440, height: 900 },
              semantics: 'layout-equivalent browser zoom: CSS viewport720x450 at deviceScaleFactor2' } : null,
            screenshot: image, pass: metrics.horizontalOverflowPx <= 1 && focus.mainLandmark === 1 && focus.headingCount === 1 && focus.positiveTabindex === 0 });
        } finally { await page.close(); }
      }
    } finally { await context.close(); }
  }
  return records;
}

async function noScriptAndPrint(browser, index, manifest, base) {
  const ownerName = manifest.overloads[0]?.owner || manifest.visuals?.[0]?.qualifiedName;
  if (!ownerName) return { status: 'not-applicable', reason: 'external corpus defines no type-page task' };
  const owner = typeEntry(index, ownerName);
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, javaScriptEnabled: false, locale: 'en-US' });
  try {
    const page = await context.newPage();
    await page.goto(new URL(owner.href, base).href);
    const rows = page.locator('[data-cjdoc-member]');
    const count = await rows.count();
    if (count >= 2) {
      await rows.first().locator(':scope > summary').click();
      await rows.last().locator(':scope > summary').click();
    }
    const noScript = { memberCount: count, independentlyOpen: count >= 2 ? await page.locator('[data-cjdoc-member][open]').count() === 2 : null,
      accessibleTree: await page.locator('main').ariaSnapshot() };
    await page.emulateMedia({ media: 'print' });
    const observePrint = () => page.evaluate(() => {
      const visible = element => {
        if (!element) return false;
        for (let node = element; node; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' ||
              Number(style.opacity) === 0 || style.contentVisibility === 'hidden') return false;
        }
        return [...element.getClientRects()].some(rect => rect.width > 0 && rect.height > 0);
      };
      const signatures = [...document.querySelectorAll('[data-cjdoc-member] summary .declaration-signature')];
      const bodies = [...document.querySelectorAll('.member-detail-body')];
      const ids = nodes => nodes.filter(visible).map(node => node.closest('[data-cjdoc-member]').id);
      const visibleSignatureIds = ids(signatures), visibleDetailIds = ids(bodies);
      return { contentVisible: visible(document.querySelector('main')),
        signatures: visibleSignatureIds.length, detailBodies: visibleDetailIds.length,
        signatureNodes: signatures.length, detailBodyNodes: bodies.length,
        visibleSignatureIds, visibleDetailIds,
        overflowPx: Math.max(0, document.documentElement.scrollWidth - innerWidth),
        semantics: 'computed ancestor visibility and rendered boxes under print media, not paper pagination' };
    });
    const print = await observePrint();
    const printCounterexamples = [];
    if (count >= 2) {
      if (!print.signatures || !print.detailBodies) throw new Error('positive native print contracts are not visible');
      let hiddenSelector = '';
      await page.route('**/style.css', async route => {
        const response = await route.fetch();
        await route.fulfill({ response, body: await response.text() +
          '\n@media print{' + hiddenSelector + '{display:none!important}}' });
      });
      for (const selector of ['.member-detail-body', '[data-cjdoc-member] summary .declaration-signature', 'main']) {
        hiddenSelector = selector;
        await page.reload();
        await rows.evaluateAll(nodes => { nodes[0].open = true; nodes[nodes.length - 1].open = true; });
        const hidden = await observePrint();
        const detected = selector === 'main' ? !hidden.contentVisible && !hidden.signatures && !hidden.detailBodies
          : selector === '.member-detail-body' ? hidden.detailBodies === 0 : hidden.signatures === 0;
        if (!detected) throw new Error('print observer missed CSS counterexample: ' + selector);
        printCounterexamples.push({ selector, detected, observation: hidden });
      }
    }
    await page.close();
    return { noScript, print, printCounterexamples,
      screenReaderSpeech: { status: 'not-measured', reason: 'ARIA tree is captured; no human or screen-reader speech session is claimed' } };
  } finally { await context.close(); }
}

const config = options();
config.site = await realpath(config.site);
config.output = path.resolve(config.output);
await mkdir(config.output, { recursive: false });
const manifestBytes = await readFile(config.manifest);
const manifest = JSON.parse(manifestBytes);
if (manifest.schemaVersion !== 'cjdoc.reader-corpus/1') throw new Error('Unsupported reader corpus manifest');
const index = await entryIndex(config.site);
const resources = await resourceSizes(config.site);
const harness = Object.fromEntries(await Promise.all(
  ['measure-reader-scale.mjs', 'reader-scale-metrics.mjs', 'reader-scale-tasks.mjs']
    .map(async name => [name, sha256(await readFile(new URL(name, import.meta.url)))])));
const hosted = await serve(config.site);
let browser;
try {
  browser = await chromium.launch({ args: ['--allow-file-access-from-files', '--js-flags=--max-old-space-size=512'] });
} catch (error) {
  await new Promise(resolve => hosted.server.close(resolve));
  throw error;
}
const report = { schemaVersion: 'cjdoc.reader-browser/1', label: config.label,
  recipe: manifest.recipe, sourceSha256: manifest.sourceSha256, taskManifestSha256: sha256(manifestBytes),
  harness,
  environment: { browser: await browser.version(), playwright: playwrightVersion, node: process.version,
    platform: process.platform, architecture: process.arch, locale: 'en-US', requestedUiLocale: config.locale,
    cpuThrottlingRate: 1,
    jsHeapLimitMiB: 512, baselineViewport: { width: 1440, height: 900, deviceScaleFactor: 1 },
    network: 'local static server without transfer compression; file has no HTTP transfer',
    taskSemantics: 'scripted browser operations and elapsed automation time, not human completion time' },
  resources, nativeIndexEntries: index.entries.length,
  transports: [], visuals: [], failures: [] };
const scrub = error => String(error.message || error).split(config.site).join('<site>').split(pathToFileURL(config.site).href).join('<site-url>');
try {
  for (const transport of config.transports) {
    const base = transport === 'file' ? pathToFileURL(config.site + path.sep).href
      : hosted.origin + (transport === 'subpath' ? '/reader-subpath/' : '/');
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, locale: 'en-US', colorScheme: 'light', reducedMotion: 'reduce' });
    await installMetrics(context);
    try {
      const loading = await loadingTask(context, index, base);
      const { page, client } = await instrumentedPage(context, new URL('index.html', base).href);
      const queries = await queryTasks(page, index, manifest, config.samples, base);
      const queryLayout = await pageMetrics(page, client);
      await page.close();
      const members = await memberTasks(context, index, manifest, base, config.samples);
      const overloads = await overloadTasks(context, index, manifest, base);
      report.transports.push({ transport, loading, queries, members, overloads, queryLayout });
    } catch (error) { report.failures.push({ transport, reason: scrub(error) }); }
    finally { await context.close(); }
  }
  const base = hosted.origin + '/';
  report.accessibility = await noScriptAndPrint(browser, index, manifest, base);
  if (config.screenshots) await visualTasks(browser, index, manifest, base, config.output, config.locale || 'native', report.visuals);
} catch (error) { report.failures.push({ scope: 'visual/accessibility', reason: scrub(error) }); }
finally {
  await browser.close();
  hosted.server.closeAllConnections?.();
  await new Promise(resolve => hosted.server.close(resolve));
  report.environment.fontFiles = await fontIdentities(report);
  await writeFile(path.join(config.output, 'reader-browser.json'), JSON.stringify(report, null, 2) + '\n');
}
console.log(JSON.stringify({ label: config.label, nativeIndexEntries: report.nativeIndexEntries,
  transports: report.transports.length, screenshots: report.visuals.length, failures: report.failures }, null, 2));
if (report.failures.length) process.exitCode = 1;
