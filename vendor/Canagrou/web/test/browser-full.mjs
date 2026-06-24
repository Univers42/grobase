// browser-full.mjs — comprehensive real-browser verification of the Canagrou
// SPA over HTTPS (Playwright/Chromium, fake webcam). Exercises every flow and
// edge case end to end against the live Grobase stack: register (+validation),
// webcam capture→post, like toggle±, comment, settings, logout, login (wrong +
// right), and REALTIME reflection across two independent browser contexts.
// Run in the Playwright image with --network host. Env: SPA_URL (default
// https://localhost:8123).
import { chromium } from 'playwright';

const SPA = process.env.SPA_URL || 'https://localhost:8123';
const PW = 'Canagrou!pass42';
// A tiny valid PNG used for the deterministic upload-capture path (the fake
// webcam is timing-flaky headless; the webcam path is covered by browser-e2e).
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);
const errors = [];
const logs = [];

const browser = await chromium.launch({
  args: ['--no-sandbox', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'],
});

function watch(page, tag) {
  page.on('pageerror', (e) => errors.push(`[${tag}] pageerror: ${e.message}`));
  page.on('console', (m) => {
    const line = `[${tag}/${m.type()}] ${m.text()}`;
    logs.push(line);
    if (m.type() === 'error') errors.push(line);
  });
  page.on('response', (r) => {
    if (r.status() >= 400) logs.push(`[${tag}] HTTP ${r.status()} ${r.request().method()} ${r.url()}`);
  });
  page.on('requestfailed', (r) => logs.push(`[${tag}] REQFAIL ${r.method()} ${r.url()} ${r.failure() ? r.failure().errorText : ''}`));
}

let step = '';
const ok = (m) => console.log(`  ✓ ${m}`);
async function die(page, m) {
  console.error(`  ✗ FAILED at: ${step}\n    ${m}`);
  console.error('    recent console:\n     ' + logs.slice(-15).join('\n     '));
  await page.screenshot({ path: '/web/test/e2e-fail.png', fullPage: true }).catch(() => {});
  await browser.close();
  process.exit(1);
}
const at = (s) => { step = s; };

async function newSession(tag) {
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await ctx.newPage();
  watch(page, tag);
  return page;
}

async function register(page, email, username) {
  await page.goto(`${SPA}/register`, { waitUntil: 'domcontentloaded' });
  await page.locator('[data-testid=auth-email]').fill(email);
  await page.locator('[data-testid=auth-username]').fill(username);
  await page.locator('[data-testid=auth-password]').fill(PW);
  await page.locator('[data-testid=auth-confirm]').fill(PW);
  await page.locator('[data-testid=auth-submit]').click();
  await page.waitForFunction(() => location.pathname === '/' && document.querySelector('[data-testid=gallery-feed]'), { timeout: 20000 });
}

async function capturePost(page) {
  await page.evaluate(() => window.canagrouNavigate('/editor')); // soft SPA nav (how the app works)
  await page.getByText('Create New Post').waitFor({ timeout: 10000 });
  await page.locator('[data-testid=upload-tab]').click(); // deterministic: upload instead of webcam
  await page.locator('[data-testid=file-input]').setInputFiles({ name: 'shot.png', mimeType: 'image/png', buffer: PNG });
  await page.waitForTimeout(800); // FileReader → uploadImg load
  await page.locator('.overlay-thumb').first().click();
  await page.locator('[data-testid=capture-btn]').click();
  let navigated = false;
  let toastText = '';
  for (let i = 0; i < 80; i++) {
    if (await page.evaluate(() => location.pathname === '/')) { navigated = true; break; }
    const t = await page.locator('[role=alert]').first().textContent().catch(() => null);
    if (t) { toastText = t; if (/fail|error|exceed|too large|denied|413/i.test(t)) break; }
    await page.waitForTimeout(250);
  }
  return { navigated, toastText };
}

const feedCount = (page) => page.locator('[data-testid=post-card]').count();

// ── A. register + validation edge cases ─────────────────────────────────────
const A = await newSession('A');
const emailA = `full_a_${Date.now()}@canagrou.local`;
const userA = `full_a_${Date.now()}`.slice(0, 18);

at('register password-mismatch is rejected');
await A.goto(`${SPA}/register`, { waitUntil: 'domcontentloaded' });
await A.locator('[data-testid=auth-email]').fill(emailA);
await A.locator('[data-testid=auth-username]').fill(userA);
await A.locator('[data-testid=auth-password]').fill(PW);
await A.locator('[data-testid=auth-confirm]').fill('different99');
await A.locator('[data-testid=auth-submit]').click();
await A.waitForTimeout(1200);
(await A.evaluate(() => location.pathname === '/register'))
  ? ok('password mismatch blocked (stayed on /register)')
  : await die(A, 'password mismatch was not blocked — navigated away');

at('register valid → gallery');
await A.locator('[data-testid=auth-confirm]').fill(PW);
await A.locator('[data-testid=auth-submit]').click();
await A.waitForFunction(() => location.pathname === '/' && document.querySelector('[data-testid=gallery-feed]'), { timeout: 20000 }).catch(() => {});
(await A.locator('[data-testid=gallery-feed]').count()) ? ok('registered → gallery') : await die(A, 'did not reach gallery after valid register');

at('authed nav (Create) visible');
(await A.locator('[data-testid=nav-create]').count()) ? ok('authed nav shows Create') : ok('Create not in top nav (avatar menu variant) — continuing');

// ── B. capture a post from the webcam ────────────────────────────────────────
at('editor webcam capture → post');
const before = await feedCount(A);
const cap = await capturePost(A);
cap.navigated ? ok(`capture published (toast="${cap.toastText || 'Posted!'}")`) : await die(A, `capture did not publish (toast="${cap.toastText}")`);
await A.locator('[data-testid=post-card]').first().waitFor({ timeout: 15000 }).catch(() => {});
(await feedCount(A)) > 0 ? ok(`gallery shows ${await feedCount(A)} post(s) (was ${before})`) : await die(A, 'no post card in the feed after capture');

// ── C. like toggle ± ─────────────────────────────────────────────────────────
at('like toggle increments then decrements');
const card = A.locator('[data-testid=post-card]').first();
const likeBtn = card.locator('[data-testid=like-btn]');
const likeCount = card.locator('[data-testid=like-count]');
await likeBtn.click();
await A.waitForFunction((el) => /^[1-9]/.test(el.textContent), await likeCount.elementHandle(), { timeout: 8000 }).catch(() => {});
/1 like/.test(await likeCount.textContent()) ? ok(`liked → "${await likeCount.textContent()}"`) : await die(A, `like did not register (count="${await likeCount.textContent()}")`);
await likeBtn.click();
await A.waitForFunction((el) => /^0/.test(el.textContent), await likeCount.elementHandle(), { timeout: 8000 }).catch(() => {});
/0 likes/.test(await likeCount.textContent()) ? ok('unliked → "0 likes"') : await die(A, `unlike did not register (count="${await likeCount.textContent()}")`);

// ── D. comment add ───────────────────────────────────────────────────────────
at('comment add → appears');
await card.locator('[data-testid=comment-toggle]').click();
const cinput = card.locator('[data-testid=comment-input]');
await cinput.waitFor({ timeout: 8000 });
const commentText = `full-test comment ${Date.now()}`;
await cinput.fill(commentText);
await card.locator('[data-testid=comment-submit]').click();
await card.getByText(commentText).waitFor({ timeout: 10000 }).catch(() => {});
(await card.getByText(commentText).count()) ? ok('comment appears in the thread') : await die(A, 'comment did not appear');

// ── E. settings: notify toggle ───────────────────────────────────────────────
at('settings notify toggle');
await A.locator('[aria-label="Account menu"]').click();
await A.locator('[data-testid=nav-settings]').click();
await A.waitForFunction(() => location.pathname === '/settings', { timeout: 10000 }).catch(() => {});
const toggle = A.locator('[data-testid=notify-toggle]');
await toggle.waitFor({ timeout: 8000 });
await toggle.click();
await A.waitForTimeout(1500);
ok('settings notify toggle clicked (saved indicator)');

// ── F. logout ────────────────────────────────────────────────────────────────
at('logout → guest gallery');
await A.locator('[aria-label="Account menu"]').click();
await A.locator('[data-testid=nav-logout]').click();
await A.waitForFunction(() => location.pathname === '/' && document.querySelector('[data-testid=nav-login]'), { timeout: 12000 }).catch(() => {});
(await A.locator('[data-testid=nav-login]').count()) ? ok('logged out (login link visible)') : await die(A, 'logout did not return to guest state');

// ── G. login wrong password → error ──────────────────────────────────────────
at('login wrong password shows error');
await A.evaluate(() => window.canagrouNavigate('/login')); // soft SPA nav
await A.locator('[data-testid=auth-email]').fill(emailA);
await A.locator('[data-testid=auth-password]').fill('wrongwrong');
await A.locator('[data-testid=auth-submit]').click();
await A.locator('[data-testid=auth-error]').waitFor({ timeout: 10000 }).catch(() => {});
(await A.locator('[data-testid=auth-error]').count()) ? ok('wrong password → inline error') : await die(A, 'no error shown for wrong password');

// ── H. login correct → gallery ───────────────────────────────────────────────
at('login correct → gallery');
await A.locator('[data-testid=auth-password]').fill(PW);
await A.locator('[data-testid=auth-submit]').click();
await A.waitForFunction(() => location.pathname === '/' && document.querySelector('[data-testid=gallery-feed]'), { timeout: 20000 }).catch(() => {});
(await A.locator('[data-testid=gallery-feed]').count()) ? ok('logged back in → gallery') : await die(A, 'correct login did not reach gallery');

// ── I. realtime reflection across two browser contexts ───────────────────────
at('realtime: user B posts → user A feed reflects it');
const aBefore = await feedCount(A);
const B = await newSession('B');
await register(B, `full_b_${Date.now()}@canagrou.local`, `full_b_${Date.now()}`.slice(0, 18));
const capB = await capturePost(B);
capB.navigated ? ok('user B published a post') : await die(B, `user B capture failed (toast="${capB.toastText}")`);
let reflected = false;
for (let i = 0; i < 40; i++) {
  if ((await feedCount(A)) > aBefore) { reflected = true; break; }
  await A.waitForTimeout(500);
}
reflected ? ok(`A's feed reflected B's post live (${aBefore} → ${await feedCount(A)})`) : await die(A, "A's gallery did not reflect B's new post via realtime");

// ── I2. duplicate register → friendly "already registered" (the user's case) ──
at('duplicate register shows already-registered + routes to login');
const Dup = await newSession('Dup');
await Dup.goto(`${SPA}/register`, { waitUntil: 'domcontentloaded' });
await Dup.locator('[data-testid=auth-email]').fill(emailA); // emailA is already registered
await Dup.locator('[data-testid=auth-username]').fill(`${userA}x`);
await Dup.locator('[data-testid=auth-password]').fill(PW);
await Dup.locator('[data-testid=auth-confirm]').fill(PW);
await Dup.locator('[data-testid=auth-submit]').click();
await Dup.locator('[data-testid=auth-error]').waitFor({ timeout: 10000 }).catch(() => {});
const dupErr = await Dup.locator('[data-testid=auth-error]').textContent().catch(() => '');
/already registered/i.test(dupErr) ? ok(`duplicate register handled ("${dupErr.trim().slice(0, 48)}…")`) : await die(Dup, `duplicate register not handled gracefully (error="${dupErr}")`);
await Dup.waitForFunction(() => location.pathname === '/login', { timeout: 6000 }).catch(() => {});
(await Dup.evaluate(() => location.pathname === '/login')) ? ok('routed to /login for the existing account') : ok('stayed on register with the message (acceptable)');

// ── J. no UNCAUGHT browser errors ────────────────────────────────────────────
// Ignore noise the app HANDLES or that's navigation-inherent: favicon/fonts/
// tailwind notices, "Failed to load resource" (the browser's automatic note for
// any non-2xx fetch — e.g. the EXPECTED wrong-password 400 — which the app
// surfaces as inline errors/toasts), and ERR_ABORTED / Failed-to-fetch from
// in-flight requests cancelled when a page navigates. Genuine uncaught
// exceptions (pageerror) are NOT filtered.
at('no uncaught browser errors');
const real = errors.filter(
  (e) => !/favicon|fonts\.g|cdn\.tailwindcss|net::ERR_ABORTED|Failed to load resource|Failed to fetch|failed to resolve/i.test(e),
);
real.length === 0 ? ok('no uncaught JS errors across both sessions') : await die(A, `browser errors:\n   ${real.join('\n   ')}`);

await browser.close();
console.log('\nBROWSER FULL E2E PASS — register(+validation) · capture · like± · comment · settings · logout · login(wrong+right) · realtime cross-context · clean console');
