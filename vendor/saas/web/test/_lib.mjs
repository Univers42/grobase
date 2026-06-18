// _lib.mjs — shared Playwright helpers for the Nimbus browser suite. Launches
// Chromium with ignoreHTTPSErrors (the SPA serves the dev-CA cert Playwright's
// bundled Chromium doesn't trust), captures console/page errors + CSP violations,
// and provides real login/logout against the live /login form. Run in the
// Playwright image with --network host so the page reaches https://localhost:8124.

import { chromium } from 'playwright';

export const SPA = process.env.SPA_URL || 'https://localhost:8124';
export const ADMIN = { email: 'admin@nimbus.local', password: 'Nimbus#2026' };
const SHOTS = '/web/test/screenshots';

/** benign filters out cert/font/favicon noise that is not an app fault. The
 *  self-hosted /fonts/*.woff2 are intentionally optional (fonts.css documents the
 *  404 → system-font fallback), so their "Failed to load resource" is by design. */
const BENIGN = /favicon|fonts\.g|\/fonts\/|\.woff2|net::ERR_CERT|ERR_ABORTED|Failed to load resource|Download the React DevTools/i;

/** launch opens a browser+context+page wired to capture errors and CSP reports.
 *  bypassCSP lets the harness inject its driver/axe scripts under the app's strict
 *  `script-src 'self'` (no unsafe-eval) WITHOUT weakening the app — the real CSP is
 *  asserted separately from the served header + page violation events. */
export async function launch({ bypassCSP = true } = {}) {
  const browser = await chromium.launch({ args: ['--no-sandbox'] });
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true, bypassCSP });
  const page = await ctx.newPage();
  const errors = [];
  const logs = [];
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
  page.on('console', (m) => {
    const line = `[${m.type()}] ${m.text()}`;
    logs.push(line);
    if (m.type() === 'error') errors.push(`console.error: ${m.text()}`);
  });
  page.on('response', (r) => {
    if (r.url().includes('csp-report')) errors.push(`csp-report: ${r.url()}`);
  });
  return { browser, ctx, page, errors, logs };
}

/** realErrors drops benign cert/font/devtools noise, keeping true app faults. */
export function realErrors(errors) {
  return errors.filter((e) => !BENIGN.test(e));
}

/** shot writes a full-page screenshot under test/screenshots/<name>.png. */
export async function shot(page, name) {
  await page.screenshot({ path: `${SHOTS}/${name}.png`, fullPage: true }).catch(() => {});
}

/** reporter builds a tiny ok/fail/die console reporter bound to one page. */
export function reporter(page, browser) {
  let step = '';
  return {
    at: (s) => { step = s; },
    ok: (m) => console.log(`  ✓ ${m}`),
    async die(m, logs) {
      console.error(`  ✗ FAILED at: ${step}\n    ${m}`);
      if (logs) console.error('    recent console:\n     ' + logs.slice(-12).join('\n     '));
      await shot(page, 'FAIL');
      await browser.close();
      process.exit(1);
    },
  };
}

/** login fills the real /login form with the given creds and waits for /app. */
export async function login(page, creds = ADMIN) {
  await page.goto(`${SPA}/login`, { waitUntil: 'domcontentloaded' });
  await page.locator('input[type="email"]').fill(creds.email);
  await page.locator('input[type="password"]').fill(creds.password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForFunction(() => location.pathname.startsWith('/app'), { timeout: 20000 });
}

/** logout clears the persisted session and reloads to the landing page. */
export async function logout(page) {
  await page.evaluate(() => localStorage.removeItem('nimbus.session'));
  await page.goto(`${SPA}/`, { waitUntil: 'domcontentloaded' });
}

/** sessionToken reads the persisted access token from localStorage, or ''. */
export async function sessionToken(page) {
  return page.evaluate(() => {
    try {
      return JSON.parse(localStorage.getItem('nimbus.session') || 'null')?.accessToken || '';
    } catch {
      return '';
    }
  });
}
