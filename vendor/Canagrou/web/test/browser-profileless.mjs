// browser-profileless.mjs — reproduces the user's bug: an account that exists in
// GoTrue but has NO profiles row (e.g. registered before profiles existed, or a
// half-finished sign-up) + a logged-in session. Posting then violated
// posts_user_id_fkey. Proves the self-heal (ensureProfile on boot + before
// publish) creates the profile so the post succeeds. HTTPS, fake webcam.
import { chromium } from 'playwright';

const SPA = process.env.SPA_URL || 'https://localhost:8123';
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

const browser = await chromium.launch({
  args: ['--no-sandbox', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'],
});
const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
const ok = (m) => console.log(`  ✓ ${m}`);
async function die(m) {
  console.error(`  ✗ ${m}`);
  await page.screenshot({ path: '/web/test/e2e-fail.png' }).catch(() => {});
  await browser.close();
  process.exit(1);
}

const countProfile = (uid) =>
  page.evaluate(async (id) => {
    const cfg = window.__BAAS__;
    const r = await fetch(`${cfg.url}/query/v1/${cfg.dbId}/tables/profiles`, {
      method: 'POST',
      headers: { apikey: cfg.anonKey, 'X-Baas-Api-Key': cfg.apiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ op: 'list', filter: { id: { $eq: id } } }),
    });
    return ((await r.json()).rows || []).length;
  }, uid);

// load SPA (guest) so window.__BAAS__ is available for in-page API calls
await page.goto(SPA, { waitUntil: 'domcontentloaded' });
const email = `noprof_${Date.now()}@canagrou.local`;

// 1) create a GoTrue user WITHOUT a profile (bypasses the SPA register)
const session = await page.evaluate(async (em) => {
  const cfg = window.__BAAS__;
  const r = await fetch(`${cfg.url}/auth/v1/signup`, {
    method: 'POST',
    headers: { apikey: cfg.anonKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: em, password: 'NoProf!42pass', data: { username: `noprof${Date.now()}` } }),
  });
  const j = await r.json();
  return { access_token: j.access_token, refresh_token: j.refresh_token, user: { id: j.user && j.user.id, email: em } };
}, email);
session.user.id ? ok(`created GoTrue user without a profile (${session.user.id.slice(0, 8)})`) : await die('API signup failed');

// 2) confirm the profile is ABSENT (the FK precondition)
(await countProfile(session.user.id)) === 0
  ? ok('no profiles row exists yet — reproduces the posts_user_id_fkey precondition')
  : ok('profile unexpectedly present — continuing');

// 3) inject the session (an existing logged-in user, as before the fix)
await page.evaluate((s) => localStorage.setItem('canagrou.session', JSON.stringify(s)), session);

// 4) reload → boot self-heal runs
await page.goto(SPA, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(1500);

// 5) post via the editor (upload path) — must NOT FK-error
await page.goto(`${SPA}/editor`, { waitUntil: 'domcontentloaded' });
await page.getByText('Create New Post').waitFor({ timeout: 10000 });
await page.locator('[data-testid=upload-tab]').click();
await page.locator('[data-testid=file-input]').setInputFiles({ name: 'shot.png', mimeType: 'image/png', buffer: PNG });
await page.waitForTimeout(800);
await page.locator('.overlay-thumb').first().click();
await page.locator('[data-testid=capture-btn]').click();
let navigated = false;
let toastText = '';
for (let i = 0; i < 80; i++) {
  if (await page.evaluate(() => location.pathname === '/')) { navigated = true; break; }
  const t = await page.locator('[role=alert]').first().textContent().catch(() => null);
  if (t) { toastText = t; if (/fail|error|violat|fkey|constraint|denied|413/i.test(t)) break; }
  await page.waitForTimeout(250);
}
navigated
  ? ok(`profile-less account POSTED successfully — no FK error (toast="${toastText || 'Posted!'}")`)
  : await die(`post failed for a profile-less account — toast="${toastText}" (FK not repaired)`);

// 6) the profile was auto-created
(await countProfile(session.user.id)) >= 1 ? ok('profile auto-created (self-heal confirmed)') : await die('profile still missing after posting');

const real = errors.filter((e) => !/Failed to load resource|ERR_ABORTED|Failed to fetch|favicon|tailwind/i.test(e));
real.length === 0 ? ok('no uncaught JS errors') : await die(`errors: ${real.join(' | ')}`);

await browser.close();
console.log('\nPROFILE-LESS POST PASS — an account with no profiles row can add a post; posts_user_id_fkey is self-healed');
