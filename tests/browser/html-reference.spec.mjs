import { test, expect } from '@playwright/test';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const fixtureRoot = process.env.CJDOC_HTML_FIXTURE;
if (!fixtureRoot) throw new Error('CJDOC_HTML_FIXTURE is required');
const indexUrl = pathToFileURL(path.resolve(fixtureRoot, 'index.html')).href;

async function openIndex(page) {
  const requests = [];
  page.on('request', request => requests.push(request.url()));
  await page.goto(indexUrl);
  expect(requests.filter(url => !url.startsWith('file:') && !url.startsWith('data:'))).toEqual([]);
  return requests;
}

test.describe('generated HTML reference', () => {
  test('overview, package rows, search and theme controls are consumer-observable', async ({ page }) => {
    await openIndex(page);
    await expect(page.locator('main h1')).toContainText('API documentation');
    await expect(page.locator('.package-index a')).toHaveCount(2);
    await expect(page.locator('[data-cjdoc-search]')).toHaveAttribute('aria-expanded', 'false');

    await page.locator('[data-cjdoc-search]').fill('ReferenceBox');
    await expect(page.locator('[data-cjdoc-results] [role="option"]')).toHaveCount(5);
    await expect(page.locator('[data-cjdoc-results] [role="option"]').first()).toContainText('ReferenceBox');
    await page.locator('[data-cjdoc-category="classes"]').click();
    await expect(page.locator('[data-cjdoc-results] [role="option"]')).toHaveCount(1);
    await page.locator('[data-cjdoc-search]').fill('no-such-declaration');
    await expect(page.locator('[data-cjdoc-search-status]')).toBeVisible();
    await page.locator('[data-cjdoc-category="all"]').click();

    await page.locator('[data-cjdoc-theme-toggle]').click();
    await expect(page.locator('[data-cjdoc-theme-popover]')).toBeVisible();
    await page.locator('[data-cjdoc-theme-value="dark"]').click();
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');

    const packageHref = await page.locator('.package-index a').first().getAttribute('href');
    const packageUrl = new URL(packageHref, indexUrl).href;
    await page.goto(packageUrl);
    await expect(page.locator('.declaration-row-link')).not.toHaveCount(0);
    const classHref = await page.locator('.declaration-row-link').first().getAttribute('href');
    const classUrl = new URL(classHref, packageUrl).href;
    await page.goto(classUrl);
    await expect(page.locator('.breadcrumbs')).toContainText('Package');
    await expect(page.locator('.source-action')).not.toHaveCount(0);
    await expect(page.locator('.source-action a')).toHaveAttribute('href', /github.com\/example\/reference\/blob\//);
    const memberHref = await page.locator('.declaration-row-link').filter({ hasText: 'normalize' }).getAttribute('href');
    const memberUrl = new URL(memberHref, classUrl).href;
    await page.goto(memberUrl);
    await expect(page.locator('.breadcrumbs')).toContainText('ReferenceBox');
    await expect(page.locator('.toc-panel')).toContainText('Parameters');
    await expect(page.locator('.toc-panel')).toContainText('Returns');
    await expect(page.locator('.code-copy')).not.toHaveCount(0);
  });

  test('mobile drawer traps focus, locks background, and restores opener', async ({ page }) => {
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
  });

  test('breakpoint layouts stay inside the viewport', async ({ page }) => {
    for (const width of [760, 761, 1180, 1181, 1440]) {
      await page.setViewportSize({ width, height: 1000 });
      await openIndex(page);
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
    }
  });
});
