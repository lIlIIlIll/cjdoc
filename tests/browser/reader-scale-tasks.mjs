import { performance } from 'node:perf_hooks';
import { distribution, frame, matchEntry, pageMetrics, timedQuery, typeEntry } from './reader-scale-metrics.mjs';

export const anchorFor = entry => 'symbol-' + Buffer.from(entry.id, 'utf8').toString('hex');
const locationKey = (value, base) => { const url = new URL(value, base); return url.pathname + url.hash; };
const matching = (hrefs, expected, base) => expected.every(entry => hrefs.some(href => locationKey(href, base) === locationKey(entry.href, base)));

export async function instrumentedPage(context, url, cacheDisabled = false) {
  const page = await context.newPage();
  const client = await context.newCDPSession(page);
  await client.send('Performance.enable');
  await client.send('Network.enable');
  await client.send('Network.setCacheDisabled', { cacheDisabled });
  await client.send('Emulation.setCPUThrottlingRate', { rate: 1 });
  await page.goto(url, { waitUntil: 'load' });
  await page.waitForSelector('[data-cjdoc-search]', { state: 'attached' });
  await page.waitForFunction(() => Array.isArray(globalThis.__CJDOC_SEARCH_INDEX__?.entries));
  return { page, client };
}

export async function queryTasks(page, index, manifest, samples, base) {
  const records = [];
  const input = page.locator('[data-cjdoc-search]');
  for (const task of manifest.queries) {
    const matchedTargets = task.expected.map(spec => index.entries.filter(entry => matchEntry(entry, spec)));
    const expected = matchedTargets.flat();
    const started = performance.now();
    await input.fill(task.query);
    await frame(page);
    const initial = await timedQuery(page, task.query);
    const sync = [], frames = [];
    for (let sample = 0; sample < samples; sample++) {
      // Measure the same fixed query rather than alternating an easier query.
      const measured = await timedQuery(page, task.query);
      if (!measured.supported) throw new Error(measured.reason);
      sync.push(measured.synchronousMs);
      frames.push(measured.frameMs);
    }
    let hrefs = initial.hrefs;
    let operations = 1;
    let continuationPages = 0;
    let continuationAvailable = false;
    if (task.expectedOutcome === 'hit' && !matching(hrefs, expected, base)) {
      const seen = new Set(hrefs);
      while (continuationPages < 2500) {
        const next = page.locator('[data-cjdoc-search-next]');
        if (!await next.count() || !await next.isVisible() || !await next.isEnabled()) break;
        continuationAvailable = true;
        await next.click();
        operations++;
        continuationPages++;
        await frame(page);
        const batch = await page.locator('[data-cjdoc-results] li a').evaluateAll(links => links.map(link => link.getAttribute('href')));
        const fresh = batch.filter(href => !seen.has(href));
        if (!fresh.length) break;
        fresh.forEach(href => seen.add(href));
        hrefs = [...seen];
        if (matching(hrefs, expected, base)) break;
      }
    }
    const expectedResolvable = task.expectedOutcome === 'absent' ? task.expected.length === 0
      : matchedTargets.length > 0 && matchedTargets.every(entries => entries.length === 1);
    const initialHit = expected.length > 0 && matching(initial.hrefs, expected, base);
    const continuedHit = expected.length > 0 && matching(hrefs, expected, base);
    const pass = expectedResolvable && (task.expectedOutcome === 'hit' ? continuedHit : initial.displayed === 0);
    records.push({ id: task.id, kind: task.kind, query: task.query, expectedOutcome: task.expectedOutcome,
      expectedIds: expected.map(entry => entry.id), expectedResolvable, first20Hit: initialHit,
      continuedHit, displayed: initial.displayed, resultStatus: initial.status,
      first20Hrefs: initial.hrefs,
      continuationAvailable, continuationPages, operationCount: operations,
      automationDurationMs: performance.now() - started, pass,
      boundary: task.expectedOutcome === 'excerpt-boundary' ? 'authored body token beyond current excerpt; not proof of absence' : null,
      synchronous: distribution(sync), frame: distribution(frames) });
    await input.fill('');
  }
  return records;
}

export async function memberTasks(context, index, manifest, base, samples) {
  const records = [];
  for (const owner of [...new Set(manifest.members.map(task => task.owner))]) {
    const ownerEntry = typeEntry(index, owner);
    const { page, client } = await instrumentedPage(context, new URL(ownerEntry.href, base).href);
    try {
      const initialLayout = await pageMetrics(page, client);
      for (const task of manifest.members.filter(item => item.owner === owner)) {
        const expected = index.entries.find(entry => entry.qualifiedName === task.qualifiedName);
        if (!expected) { records.push({ id: task.id, pass: false, reason: 'expected native member identity absent' }); continue; }
        const started = performance.now();
        const name = expected.name;
        const timings = await page.evaluate(async ({ name, count }) => {
          const input = document.querySelector('[data-cjdoc-member-filter]');
          if (!input) return null;
          const raw = [];
          for (let sample = 0; sample < count; sample++) {
            input.value = sample % 2 ? name : '';
            const start = performance.now();
            input.dispatchEvent(new Event('input', { bubbles: true }));
            const synchronousMs = performance.now() - start;
            await new Promise(resolve => requestAnimationFrame(resolve));
            raw.push({ synchronousMs, frameMs: performance.now() - start });
          }
          return raw;
        }, { name, count: samples });
        const filter = page.locator('[data-cjdoc-member-filter]');
        await filter.fill(name);
        await frame(page);
        const target = page.locator('#' + anchorFor(expected));
        const foundByBodyFilter = await target.count() === 1 && await target.isVisible();
        // A deliberately conflicting filter must not suppress a precise deep link.
        await filter.fill('rdr_no_matching_member');
        await page.goto(new URL(ownerEntry.href, base).href + '#' + anchorFor(expected));
        await page.waitForFunction(id => {
          const row = document.getElementById(id);
          return row && !row.hidden && row.open;
        }, anchorFor(expected));
        const deepLink = await target.isVisible() && await target.getAttribute('open') !== null;
        const state = await page.evaluate(() => ({
          filter: document.querySelector('[data-cjdoc-member-filter]')?.value,
          visibleMembers: [...document.querySelectorAll('[data-cjdoc-member]')].filter(row => !row.hidden).length,
          sidebarTruncated: Boolean(document.querySelector('.sidebar-limit')),
          contextItems: document.querySelectorAll('[data-cjdoc-context-item]').length,
        }));
        records.push({ id: task.id, owner, expectedId: expected.id, ordinal: task.ordinal,
          foundByBodyFilter, deepLink, state, pass: foundByBodyFilter && deepLink,
          operationCount: 3, automationDurationMs: performance.now() - started,
          synchronous: distribution((timings || []).map(item => item.synchronousMs)),
          frame: distribution((timings || []).map(item => item.frameMs)),
          metricsSupport: timings ? 'measured' : 'unsupported', initialLayout,
          finalLayout: await pageMetrics(page, client) });
      }
    } finally { await page.close(); }
  }
  return records;
}

export async function overloadTasks(context, index, manifest, base) {
  const records = [];
  for (const task of manifest.overloads) {
    const ownerEntry = typeEntry(index, task.owner);
    const { page, client } = await instrumentedPage(context, new URL(ownerEntry.href, base).href);
    try {
      const selections = [];
      for (const position of new Set([0, Math.floor(task.targets.length / 2), task.targets.length - 1])) {
        const target = task.targets[position];
        const expected = index.entries.find(entry => matchEntry(entry, target));
        if (!expected) { selections.push({ callShape: target.callShape, pass: false, reason: 'native structured identity absent' }); continue; }
        const query = 'owner:' + task.owner.split('.').at(-1) + ' param:' + target.parameterTypes[0];
        const started = performance.now();
        await page.locator('[data-cjdoc-search]').fill(query);
        await frame(page);
        const first = page.locator('[data-cjdoc-results] li a').first();
        const href = await first.getAttribute('href');
        const selectedCorrectly = locationKey(href, page.url()) === locationKey(expected.href, base);
        if (selectedCorrectly) {
          await first.click();
          await page.waitForSelector('main');
        }
        selections.push({ callShape: target.callShape, query, expectedId: expected.id,
          pass: selectedCorrectly, operationCount: selectedCorrectly ? 2 : 1,
          automationDurationMs: performance.now() - started });
        await page.goto(new URL(ownerEntry.href, base).href);
        await page.waitForSelector('[data-cjdoc-member-filter]');
      }
      const started = performance.now();
      await page.locator('[data-cjdoc-member-filter]').fill(task.name);
      const targets = [task.targets[0], task.targets.at(-1)].map(spec => index.entries.find(entry => matchEntry(entry, spec)));
      const details = [];
      for (const target of targets) {
        if (!target) continue;
        const row = page.locator('#' + anchorFor(target));
        await row.locator(':scope > summary').click();
        details.push({ id: target.id, signature: await row.locator(':scope > summary code').first().textContent(),
          authoredDetails: await row.locator('.member-detail-body').innerText() });
      }
      const openIds = await page.locator('[data-cjdoc-member][open]').evaluateAll(rows => rows.map(row => row.id));
      const simultaneouslyOpen = targets.every(target => target && openIds.includes(anchorFor(target)));
      const comparison = { operationCount: 3, automationDurationMs: performance.now() - started,
        simultaneouslyOpen, details, semantics: 'rendered author text and exact native identities; no correctness inference' };
      await page.goto(new URL('index.html', base).href);
      await page.goBack({ waitUntil: 'load' });
      await page.waitForSelector('[data-cjdoc-member-filter]');
      const restored = await page.locator('[data-cjdoc-member][open]').evaluateAll(rows => rows.map(row => row.id));
      const historyRestored = targets.every(target => target && restored.includes(anchorFor(target)));
      records.push({ id: task.id, count: task.count, selections, comparison, historyRestored,
        pass: selections.every(item => item.pass) && simultaneouslyOpen && historyRestored,
        layout: await pageMetrics(page, client) });
    } finally { await page.close(); }
  }
  return records;
}
