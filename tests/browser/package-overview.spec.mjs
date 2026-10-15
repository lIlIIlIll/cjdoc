import { test, expect } from '@playwright/test';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const root = path.resolve(process.env.CJDOC_PACKAGE_OVERVIEW_SITE || '');
if (!process.env.CJDOC_PACKAGE_OVERVIEW_SITE) throw new Error('CJDOC_PACKAGE_OVERVIEW_SITE is required');
const cases = JSON.parse(await readFile(path.join(root, 'package-overview-receipt.json'), 'utf8'));
const shots = process.env.CJDOC_PACKAGE_OVERVIEW_SCREENSHOTS;
let server;
let base;

test.beforeAll(async () => {
  if (shots) await mkdir(shots, { recursive: true });
  server = createServer(async (request, response) => {
    const url = new URL(request.url || '/', 'http://localhost');
    if (!url.pathname.startsWith('/reference/subpath/')) return response.writeHead(404).end();
    const file = path.resolve(root, decodeURIComponent(url.pathname.slice('/reference/subpath/'.length)));
    if (!file.startsWith(root + path.sep)) return response.writeHead(404).end();
    try {
      const body = await readFile(file);
      response.writeHead(200, { 'Content-Type': ({ '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json' })[path.extname(file)] || 'application/octet-stream' });
      response.end(body);
    } catch { response.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}/reference/subpath/`;
});
test.afterAll(async () => { if (server) await new Promise(resolve => server.close(resolve)); });

for (const mode of ['file', 'http']) {
  for (const fixture of cases) {
    test(`${mode}: ${fixture.name} preserves package identity and actual return anchor`, async ({ page }) => {
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      const destination = mode === 'file' ? pathToFileURL(path.join(root, fixture.package)).href : base + fixture.package;
      await page.goto(destination);
      await expect(page.locator('main h1')).toContainText('pocketkit');
      await expect(page.locator('main')).toContainText(fixture.apiMarker);
      await expect(page.locator('main')).not.toContainText(fixture.forbiddenApiMarker);
      const overview = page.locator('.package-overview');
      if (fixture.authored) {
        await expect(overview).toBeVisible();
        await expect(overview).toContainText(fixture.summary);
        await expect(overview).not.toContainText('catalogue-workflow-full-text');
        await expect(overview.locator('pre')).toHaveCount(0);
        await expect(overview.locator('h1, h2')).toHaveCount(0);
        if (shots && fixture.name === 'authored-en') await page.screenshot({ path: path.join(shots, test.info().project.name + '-' + mode + '-authored.png') });
        await overview.locator('.package-overview-link').click();
        const expectedGuide = mode === 'file' ? pathToFileURL(path.join(root, fixture.guide)).href : base + fixture.guide;
        await expect(page).toHaveURL(expectedGuide);
        await expect(page.locator('html')).toHaveAttribute('lang', fixture.locale);
        await expect(page.locator('main')).toContainText(fixture.bodyMarker);
        for (const marker of fixture.forbiddenBodyMarkers) await expect(page.locator('main')).not.toContainText(marker);
        await expect(page.locator('main h1')).toHaveCount(1);
        await expect(page.locator('main pre')).toBeVisible();
        await page.locator('.package-api-return a').click();
        await expect(page).toHaveURL(destination + '#declarations');
        await expect(page.locator('#declarations')).toBeInViewport();
        await expect(page.locator('main h1')).toContainText('pocketkit');
        await expect(page.locator('main')).toContainText(fixture.apiMarker);
        await expect(page.locator('main')).not.toContainText(fixture.forbiddenApiMarker);
        await page.reload();
        await expect(page).toHaveURL(destination + '#declarations');
        await expect(page.locator('#declarations')).toBeInViewport();
      } else {
        await expect(overview).toHaveCount(0);
        await expect(page.locator('.package-overview-link')).toHaveCount(0);
        await expect(page.locator('main')).not.toContainText('This page describes');
        await expect(page.locator('#declarations')).toBeInViewport();
        // Follow the first real API entry, not only its href, then browser-back.
        const entry = page.locator('main .declaration-index a, main .package-declarations a, main a').filter({ hasText: 'Entry' }).first();
        await entry.click();
        await expect(page.locator('main h1')).toContainText('Entry');
        await page.goBack();
        await expect(page).toHaveURL(destination);
        await expect(page.locator('#declarations')).toBeInViewport();
        await expect(page.locator('main')).toContainText(fixture.apiMarker);
        await expect(page.locator('main')).not.toContainText(fixture.forbiddenApiMarker);
        if (shots && fixture.name === 'unconfigured') await page.screenshot({ path: path.join(shots, test.info().project.name + '-' + mode + '-compact.png') });
      }
      expect(errors).toEqual([]);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
    });
  }
}
