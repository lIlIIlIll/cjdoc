import { defineConfig } from '@playwright/test';
import reference from './playwright.config.mjs';

export default defineConfig({
  ...reference,
  testMatch: /package-overview\.spec\.mjs$/,
  fullyParallel: false,
  workers: 1,
  projects: [
    { name: 'desktop', use: { viewport: { width: 1440, height: 900 }, colorScheme: 'light' } },
    { name: 'mobile', use: { viewport: { width: 390, height: 844 }, colorScheme: 'dark' } },
    { name: 'no-js', use: { viewport: { width: 1440, height: 900 }, colorScheme: 'light', javaScriptEnabled: false } },
  ],
});
