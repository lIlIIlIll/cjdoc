import { defineConfig } from '@playwright/test';
import reference from './playwright.config.mjs';

export default defineConfig({
  ...reference,
  testMatch: /html-admonition\.spec\.mjs$/,
  fullyParallel: false,
  retries: 0,
});
