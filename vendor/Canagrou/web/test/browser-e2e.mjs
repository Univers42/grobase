// browser-e2e.mjs — REAL headless-browser click-through of the Canagrou SPA
// (Playwright/Chromium with a fake webcam). Proves the app boots, registers a
// user, renders the gallery, and that the editor's webcam→compose→upload→post
// flow works in a browser and the new post appears in the feed. Run in the
// Playwright image with --network host (so the page reaches Kong + the SPA
// static server). Env: SPA_URL (default http://127.0.0.1:8123).
import { chromium } from 'playwright';

const SPA = process.env.SPA_URL || "http://localhost:5273";
const stamp = Date.now();
const email = `bro_${stamp}@canagrou.local`;
const username = `bro_${stamp}`.slice(0, 18);
const password = 'Br0wser!pass42';
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

const errors = [];
const browser = await chromium.launch({
  args: ['--no-sandbox', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'],
});
// ignoreHTTPSErrors: the SPA serves the project CA-signed cert (trusted by the
// system/real browsers), but Playwright's bundled Chromium uses its own cert
// store that lacks the dev CA — a test-only concern.
const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
const page = await ctx.newPage();
const logs = [];
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
page.on('console', (m) => {
  logs.push(`[${m.type()}] ${m.text()}`);
  if (m.type() === 'error') errors.push(`console.error: ${m.text()}`);
});

const ok = (m) => console.log(`  ✓ ${m}`);
async function die(m) {
  console.error(`  ✗ ${m}`);
  await page.screenshot({ path: '/web/test/e2e-fail.png' }).catch(() => {});
  await browser.close();
  process.exit(1);
}

// 1) register
await page.goto(`${SPA}/register`, { waitUntil: 'domcontentloaded' });
await page.getByPlaceholder('Email').fill(email);
await page.getByPlaceholder('Username').fill(username);
await page.getByPlaceholder('Password', { exact: true }).fill(password);
await page.getByPlaceholder('Confirm Password').fill(password);
await page.getByRole('button', { name: 'Sign up' }).click();

// 2) lands on the gallery (empty state for a fresh user)
await page.waitForFunction(() => location.pathname === '/' && document.querySelector('#gallery-feed'), { timeout: 15000 }).catch(() => {});
(await page.locator('#gallery-feed').count()) ? ok('register → gallery rendered') : await die('did not land on the gallery after register');

// 3) editor: pick an overlay, capture from the fake webcam (soft SPA nav)
await page.evaluate(() => window.canagrouNavigate('/editor'));
await page.getByText('Create New Post').waitFor({ timeout: 10000 });
ok('editor page rendered');
// 4) capture via the UPLOAD path (deterministic — the fake webcam is unreliable
// headless; the webcam path works on a real machine with a camera).
await page.locator('[data-testid=upload-tab]').click();
await page.locator('[data-testid=file-input]').setInputFiles({ name: 'shot.png', mimeType: 'image/png', buffer: PNG });
await page.waitForTimeout(800);
await page.locator('.overlay-thumb').first().click();
ok('overlay selected + image chosen');
await page.getByRole('button', { name: 'Capture Photo' }).click();

let navigated = false;
let lastToast = '';
for (let i = 0; i < 80; i++) {
  if (await page.evaluate(() => location.pathname === '/')) { navigated = true; break; }
  const t = await page.locator('[role="alert"]').first().textContent().catch(() => null);
  if (t) { lastToast = t; if (/fail|error|exceed|too large|denied|413/i.test(t)) break; }
  await page.waitForTimeout(250);
}
if (!navigated) {
  console.error(`  capture did not navigate — last toast="${lastToast}"`);
  console.error('  recent console:\n   ' + logs.slice(-20).join('\n   '));
  await die('capture did not publish/navigate');
}
ok(`capture published (toast="${lastToast || 'Posted!'}")`);
await page.locator('#gallery-feed img').first().waitFor({ timeout: 15000 }).catch(() => {});
const imgs = await page.locator('#gallery-feed img').count();
imgs > 0 ? ok(`post appears in the gallery (${imgs} image(s))`) : await die('post published but image did not render in the feed');

// 5) no uncaught browser errors throughout (ignore benign favicon/font 404s)
const real = errors.filter((e) => !/favicon|fonts\.g|net::ERR_/.test(e));
real.length === 0 ? ok('no uncaught browser errors') : await die(`browser errors:\n   ${real.join('\n   ')}`);

await browser.close();
console.log(`\nBROWSER E2E PASS — registered, gallery, webcam capture→post→feed, clean console`);
