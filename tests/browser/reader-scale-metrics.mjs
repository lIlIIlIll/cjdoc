import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { readFile, stat } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';
import path from 'node:path';

const require = process.env.CJDOC_BROWSER_REQUIRE_ROOT
  ? createRequire(path.join(path.resolve(process.env.CJDOC_BROWSER_REQUIRE_ROOT), 'package.json'))
  : createRequire(import.meta.url);
export const { chromium } = require('@playwright/test');
export const playwrightVersion = require('@playwright/test/package.json').version;
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
export const quantile = (values, fraction) => values.length
  ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * fraction) - 1)] : null;
export const distribution = values => ({ samples: values, p50Ms: quantile(values, .5), p95Ms: quantile(values, .95) });

export async function resourceSizes(site) {
  const resources = {};
  for (const name of ['search-index.json', 'search-index.js', 'search.js', 'style.css']) {
    const bytes = await readFile(path.join(site, name));
    resources[name] = { bytes: bytes.length, gzipBytes: gzipSync(bytes, { mtime: 0 }).length, sha256: sha256(bytes) };
  }
  return resources;
}

export async function installMetrics(context) {
  await context.addInitScript(() => {
    const state = { longTasks: [], longTaskSupport: false, scrollPx: 0, scrollEvents: 0,
      trustedEvents: 0, syntheticEvents: 0, clicks: 0, keydowns: 0, inputs: 0 };
    globalThis.__READER_BENCHMARK__ = state;
    try {
      const observer = new PerformanceObserver(list => {
        for (const entry of list.getEntries()) state.longTasks.push({ startMs: entry.startTime, durationMs: entry.duration });
      });
      observer.observe({ type: 'longtask', buffered: true });
      state.longTaskSupport = true;
    } catch (_) { /* Explicit unsupported state is emitted in the report. */ }
    const positions = new WeakMap();
    document.addEventListener('scroll', event => {
      const target = event.target === document ? document.scrollingElement : event.target;
      const previous = positions.get(target) || { x: 0, y: 0 };
      const next = { x: target.scrollLeft || 0, y: target.scrollTop || 0 };
      state.scrollPx += Math.abs(next.x - previous.x) + Math.abs(next.y - previous.y);
      state.scrollEvents++;
      positions.set(target, next);
    }, true);
    for (const [name, key] of [['click', 'clicks'], ['keydown', 'keydowns'], ['input', 'inputs']]) {
      document.addEventListener(name, event => {
        state[key]++;
        state[event.isTrusted ? 'trustedEvents' : 'syntheticEvents']++;
      }, true);
    }
  });
}

export async function frame(page) {
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

export async function pageMetrics(page, attachedClient = null) {
  const client = attachedClient || await page.context().newCDPSession(page);
  if (!attachedClient) await client.send('Performance.enable');
  const performanceMetrics = await client.send('Performance.getMetrics');
  const values = Object.fromEntries(performanceMetrics.metrics.map(item => [item.name, item.value]));
  let fonts = null;
  try {
    await client.send('DOM.enable');
    await client.send('CSS.enable');
    const dom = await client.send('DOM.getDocument', { depth: 0 });
    fonts = [];
    for (const selector of ['body', 'main h1', 'main p', '.declaration-signature',
      '[data-cjdoc-member][open] .declaration-signature', 'pre code']) {
      const node = await client.send('DOM.querySelector', { nodeId: dom.root.nodeId, selector });
      if (!node.nodeId) continue;
      const sampled = (await client.send('CSS.getPlatformFontsForNode', { nodeId: node.nodeId })).fonts;
      fonts.push(...sampled.map(font => ({ ...font, sampleSelector: selector })));
    }
  } catch (_) { fonts = null; /* Unsupported font identity is not an empty measurement. */ }
  if (!attachedClient) await client.detach();
  const layout = await page.evaluate(() => {
    const rect = element => {
      if (!element) return null;
      const box = element.getBoundingClientRect();
      return { width: box.width, height: box.height, scrollWidth: element.scrollWidth,
        scrollHeight: element.scrollHeight, clientWidth: element.clientWidth, clientHeight: element.clientHeight };
    };
    const tocLinks = [...document.querySelectorAll('.on-this-page a, .toc a, [data-cjdoc-toc] a')];
    const contextLinks = [...document.querySelectorAll('[data-cjdoc-context-item]')];
    const wrapped = tocLinks.filter(link => link.getBoundingClientRect().height > parseFloat(getComputedStyle(link).lineHeight) * 1.6);
    const measurements = globalThis.__READER_BENCHMARK__;
    return { domNodes: document.getElementsByTagName('*').length,
      documentLocale: document.documentElement.lang,
      horizontalOverflowPx: Math.max(0, document.documentElement.scrollWidth - innerWidth),
      viewport: { width: innerWidth, height: innerHeight, deviceScaleFactor: devicePixelRatio },
      body: rect(document.body), memberBrowser: rect(document.querySelector('[data-cjdoc-member-browser]')),
      toc: { links: tocLinks.length, wrappedLinks: wrapped.length },
      context: { links: contextLinks.length },
      typography: { bodyFont: getComputedStyle(document.body).fontFamily,
        bodyFontSize: getComputedStyle(document.body).fontSize },
      interactions: measurements || null,
      resourceTiming: performance.getEntriesByType('resource').map(entry => ({
        name: new URL(entry.name).pathname.split('/').pop(), durationMs: entry.duration,
        transferBytes: entry.transferSize, decodedBytes: entry.decodedBodySize })),
      navigation: performance.getEntriesByType('navigation').map(entry => ({
        domInteractiveMs: entry.domInteractive, domContentLoadedMs: entry.domContentLoadedEventEnd,
        loadMs: entry.loadEventEnd, responseEndMs: entry.responseEnd })),
    };
  });
  return { ...layout, jsHeapUsedBytes: values.JSHeapUsedSize ?? null,
    jsHeapTotalBytes: values.JSHeapTotalSize ?? null, scriptCpuMs: values.ScriptDuration === undefined ? null : values.ScriptDuration * 1000,
    taskCpuMs: values.TaskDuration === undefined ? null : values.TaskDuration * 1000,
    fonts: fonts === null ? null : fonts.map(font => ({ family: font.familyName, postScriptName: font.postScriptName,
      glyphs: font.glyphCount, custom: font.isCustomFont, sampleSelector: font.sampleSelector })),
    cpuCounterScope: attachedClient ? 'instrumented before navigation' : 'late attachment; not a load CPU measurement',
    memorySemantics: 'CDP JavaScript heap, not browser process RSS; unavailable values are null' };
}

export async function timedQuery(page, query) {
  return page.evaluate(async value => {
    const input = document.querySelector('[data-cjdoc-search]');
    if (!input) return { supported: false, reason: 'native search control absent' };
    const start = performance.now();
    input.value = value;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    const synchronousMs = performance.now() - start;
    await new Promise(resolve => requestAnimationFrame(resolve));
    return { supported: true, synchronousMs, frameMs: performance.now() - start,
      hrefs: [...document.querySelectorAll('[data-cjdoc-results] li a')].map(link => link.getAttribute('href')),
      status: document.querySelector('[data-cjdoc-search-status]')?.textContent || '',
      displayed: document.querySelectorAll('[data-cjdoc-results] li').length };
  }, query);
}

export async function entryIndex(site) {
  const file = path.join(site, 'search-index.json');
  const index = JSON.parse(await readFile(file, 'utf8'));
  if (index.schemaVersion !== 'cjdoc.search-index/9' || !Array.isArray(index.entries)) throw new Error('Unsupported native search index');
  return index;
}

export function matchEntry(entry, expected) {
  if (entry.qualifiedName !== expected.qualifiedName) return false;
  return !expected.parameterTypes || JSON.stringify(entry.parameterTypes) === JSON.stringify(expected.parameterTypes);
}

export function typeEntry(index, qualifiedName) {
  const matches = index.entries.filter(entry => entry.qualifiedName === qualifiedName && ['class', 'struct', 'interface'].includes(entry.kind));
  if (matches.length !== 1) throw new Error('Expected unique native type identity: ' + qualifiedName);
  return matches[0];
}

export async function screenshot(page, output, name) {
  const filename = name + '.png';
  const destination = path.join(output, filename);
  await page.screenshot({ path: destination, fullPage: false });
  const bytes = await readFile(destination);
  return { path: filename, bytes: (await stat(destination)).size, sha256: sha256(bytes) };
}
