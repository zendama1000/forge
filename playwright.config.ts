import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright E2E test configuration
 * 占いウェブサービス (Fortune-telling web service) E2E tests
 * Server URL: http://localhost:3000
 */
export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  forbidOnly: !!process.env['CI'],
  retries: process.env['CI'] ? 2 : 0,
  workers: process.env['CI'] ? 1 : undefined,
  reporter: 'html',
  use: {
    baseURL: 'http://localhost:3000',
    trace: 'on-first-retry',
    animations: 'disabled',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
