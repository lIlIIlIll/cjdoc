import { chromium } from '@playwright/test';
import { readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const [baselineRootArg, currentRootArg, outputArg, baselineMsArg, currentMsArg] = process.argv.slice(2);
if (!baselineRootArg || !currentRootArg || !outputArg) {
  throw new Error('usage: measure-reference-density.mjs <baseline-html> <current-html> <output-json> [baseline-ms] [current-ms]');
}
const baselineRoot = path.resolve(baselineRootArg);
const currentRoot = path.resolve(currentRootArg);

async function findReferenceBox(root) {
  const symbolDir = path.join(root, 'symbols');
  for (const name of await readdir(symbolDir)) {
    if (!name.endsWith('.html')) continue;
    const file = path.join(symbolDir, name);
    const text = await readFile(file, 'utf8');
    if (text.includes('<code>ReferenceBox</code>') && text.includes('data-cjdoc-member-browser')) return file;
  }
  throw new Error('ReferenceBox type page not found under ' + root);
}

async function resourceBytes(root, typePage) {
  let total = (await stat(typePage)).size;
  for (const name of ['style.css', 'search.js', 'search-index.js']) {
    total += (await stat(path.join(root, name))).size;
  }
  return total;
}

async function measure(browser, root) {
  const typePage = await findReferenceBox(root);
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await page.goto(pathToFileURL(typePage).href);
  const browserNode = page.locator('[data-cjdoc-member-browser]');
  await browserNode.scrollIntoViewIfNeeded();
  const layout = await page.evaluate(async () => {
    const rows = [...document.querySelectorAll('[data-cjdoc-member]')]
      .filter(row => !row.dataset.memberOrigin || row.dataset.memberOrigin === 'declared');
    const rowRects = rows.map(row => row.getBoundingClientRect());
    const input = document.querySelector('[data-cjdoc-member-filter]');
    const frameTimes = [];
    if (input) {
      for (let index = 0; index < 12; index += 1) {
        const started = performance.now();
        input.value = index % 2 ? '' : 'normalize';
        input.dispatchEvent(new Event('input', {bubbles: true}));
        await new Promise(resolve => requestAnimationFrame(resolve));
        frameTimes.push(performance.now() - started);
      }
      input.value = '';
      input.dispatchEvent(new Event('input', {bubbles: true}));
    }
    frameTimes.sort((a, b) => a - b);
    const first = rows[0];
    return {
      declaredMembers: rows.length,
      visibleMembersAtBrowserStart: rowRects.filter(rect => rect.bottom > 0 && rect.top < innerHeight).length,
      collapsedRowsHeightPx: Math.round(rowRects.reduce((sum, rect) => sum + rect.height, 0) * 100) / 100,
      averageRowHeightPx: Math.round((rowRects.reduce((sum, rect) => sum + rect.height, 0) / Math.max(1, rowRects.length)) * 100) / 100,
      memberBrowserHeightPx: Math.round(document.querySelector('[data-cjdoc-member-browser]').getBoundingClientRect().height * 100) / 100,
      domNodes: document.getElementsByTagName('*').length,
      filterFrameMedianMs: frameTimes.length ? Math.round(frameTimes[Math.floor(frameTimes.length / 2)] * 100) / 100 : null,
      inlineFullDetail: Boolean(first && first.tagName === 'DETAILS' && first.querySelector('.member-detail-body')),
    };
  });
  layout.typePageBytes = (await stat(typePage)).size;
  layout.referenceResourceBytes = await resourceBytes(root, typePage);
  await page.close();
  return layout;
}

const browser = await chromium.launch();
try {
  const baseline = await measure(browser, baselineRoot);
  const current = await measure(browser, currentRoot);
  const evidence = {
    baselineCommit: 'c0ec28b6698e16da4e02cf7f59ff08d8e20fadf0',
    fixture: 'tests/fixtures/projects/html_reference',
    viewport: {width: 1440, height: 900},
    baselineGenerationMs: Number(baselineMsArg || 0),
    currentGenerationMs: Number(currentMsArg || 0),
    baseline,
    current,
    delta: {
      visibleMembers: current.visibleMembersAtBrowserStart - baseline.visibleMembersAtBrowserStart,
      collapsedRowsHeightPx: Math.round((current.collapsedRowsHeightPx - baseline.collapsedRowsHeightPx) * 100) / 100,
      typePageBytes: current.typePageBytes - baseline.typePageBytes,
      domNodes: current.domNodes - baseline.domNodes,
    }
  };
  if (!current.inlineFullDetail) throw new Error('current type page does not expose inline full member details');
  if (current.declaredMembers < 20) throw new Error('density fixture must expose at least 20 declared members');
  if (current.filterFrameMedianMs !== null && current.filterFrameMedianMs > 100) {
    throw new Error('member filter median frame latency exceeds 100ms');
  }
  if (current.typePageBytes > 512 * 1024) throw new Error('ReferenceBox type page exceeds 512KiB');
  if (current.domNodes > 8000) throw new Error('ReferenceBox DOM exceeds 8000 nodes');
  await writeFile(path.resolve(outputArg), JSON.stringify(evidence, null, 2) + '\n', 'utf8');
  console.log(JSON.stringify(evidence, null, 2));
} finally {
  await browser.close();
}
