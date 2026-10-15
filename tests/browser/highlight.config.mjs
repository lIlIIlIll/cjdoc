import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: /highlight\.spec\.mjs$/,
  workers: 1,
  forbidOnly: !!process.env.CI,
  reporter: 'list',
  use: { viewport: { width: 1440, height: 900 }, colorScheme: 'light', screenshot: 'only-on-failure', trace: 'retain-on-failure' },
});
