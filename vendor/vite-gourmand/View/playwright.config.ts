import { defineConfig, devices } from '@playwright/test';

const frontendUrl = process.env.PLAYWRIGHT_BASE_URL ?? 'http://localhost:5173';
const skipWebServer = process.env.PLAYWRIGHT_SKIP_WEB_SERVER === '1';

export default defineConfig({
  testDir: './tests/e2e',
  timeout: 30_000,
  expect: { timeout: 10_000 },
  fullyParallel: true,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: frontendUrl,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  webServer: skipWebServer
    ? undefined
    : {
        command: 'npm run dev -- --host 0.0.0.0',
        url: frontendUrl,
        reuseExistingServer: true,
        timeout: 120_000,
      },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
