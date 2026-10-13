import { defineConfig } from '@playwright/test';
import reference from './playwright.config.mjs';

export default defineConfig({
  ...reference,
  testMatch: /i18n\.spec\.mjs$/,
  fullyParallel: false,
  use: { ...reference.use, trace: 'on' },
});
