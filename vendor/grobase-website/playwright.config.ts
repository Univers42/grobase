import { defineConfig, devices } from '@playwright/test';

// Docker-first: the e2e run uses the audit image's system Chromium (apk) via
// CHROME_PATH — Playwright never downloads a browser (matches the --ignore-scripts
// supply-chain rule). The webServer builds the PROD bundle (NODE_ENV=production →
// the hashed CSP meta) and previews it, exactly as the Lighthouse/csp gate does.
const executablePath = process.env.CHROME_PATH || process.env.PUPPETEER_EXECUTABLE_PATH || undefined;
const launchOptions = { executablePath, args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'] };

export default defineConfig({
	testDir: './e2e',
	outputDir: './test-results/e2e',
	timeout: 60_000,
	expect: { timeout: 10_000 },
	fullyParallel: false,
	workers: 1,
	retries: 0,
	reporter: [['list']],
	use: {
		baseURL: 'http://127.0.0.1:4325',
		launchOptions,
	},
	projects: [
		{ name: 'desktop', use: { ...devices['Desktop Chrome'], launchOptions } },
		{ name: 'mobile', use: { ...devices['Pixel 5'], launchOptions } },
	],
	webServer: {
		command: 'npm run build && npm run preview',
		url: 'http://127.0.0.1:4325/',
		reuseExistingServer: true,
		timeout: 180_000,
		stdout: 'pipe',
		stderr: 'pipe',
	},
});
