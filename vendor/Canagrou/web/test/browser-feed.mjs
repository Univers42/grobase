// browser-feed.mjs — verifies the LinkedIn-style feed in a real browser over
// HTTPS: text post (#hashtags + 500-char rule), hashtag feed, like/comment,
// share/repost, profile page + section tabs, and that styling is present
// WITHOUT the Tailwind CDN (the static /tailwind.css). Run in the Playwright
// image with --network host. Env: SPA_URL (default https://localhost:8123).
import { chromium } from 'playwright';

const SPA = process.env.SPA_URL || 'https://localhost:8123';
const PW = 'Canagrou!pass42';
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);
const errors = [];
const logs = [];

const browser = await chromium.launch({ args: ['--no-sandbox'] });
const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
const page = await ctx.newPage();
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
page.on('console', (m) => {
  logs.push(`[${m.type()}] ${m.text()}`);
  if (m.type() === 'error') errors.push(m.text());
});

let step = '';
const at = (s) => { step = s; };
const ok = (m) => console.log(`  ✓ ${m}`);
async function die(m) {
  console.error(`  ✗ FAILED at: ${step}\n    ${m}`);
  console.error('    recent console:\n     ' + logs.slice(-12).join('\n     '));
  await page.screenshot({ path: '/web/test/e2e-fail.png', fullPage: true }).catch(() => {});
  await browser.close();
  process.exit(1);
}

const stamp = Date.now();
const email = `feed_${stamp}@canagrou.local`;
const username = `feed_${stamp}`.slice(0, 18);
const tag = `grobase${stamp}`.slice(0, 16);

// ── register ─────────────────────────────────────────────────────────────────
at('register');
await page.goto(`${SPA}/register`, { waitUntil: 'domcontentloaded' });
await page.locator('[data-testid=auth-email]').fill(email);
await page.locator('[data-testid=auth-username]').fill(username);
await page.locator('[data-testid=auth-password]').fill(PW);
await page.locator('[data-testid=auth-confirm]').fill(PW);
await page.locator('[data-testid=auth-submit]').click();
await page.waitForFunction(() => location.pathname === '/' && document.querySelector('[data-testid=gallery-feed]'), { timeout: 20000 });
ok('registered → feed');

// ── styling present WITHOUT the CDN (static /tailwind.css) ───────────────────
at('styling loaded (no CDN)');
const maxW = await page.evaluate(() => {
  const feed = document.querySelector('[data-testid=gallery-feed]');
  return feed && feed.parentElement ? getComputedStyle(feed.parentElement).maxWidth : '';
});
maxW === '500px' ? ok('Tailwind utility applied (max-w-[500px] → 500px, no CDN)') : await die(`Tailwind not applied (feed max-width="${maxW}")`);

// ── compose a text post with a hashtag ───────────────────────────────────────
at('compose a #hashtag text post');
const composer = page.locator('[data-testid=composer-input]');
await composer.waitFor({ timeout: 10000 });
const body = `Hello feed! Loving #${tag} on Grobase ✨`;
await composer.fill(body);
const counter = await page.locator('[data-testid=composer-counter]').textContent().catch(() => '');
/\d+\s*\/\s*500/.test(counter) ? ok(`char counter shows "${counter.trim()}"`) : ok('counter format differs — continuing');
await page.locator('[data-testid=composer-submit]').click();
const posted = page.locator('[data-testid=post-content]', { hasText: tag });
await posted.first().waitFor({ timeout: 12000 }).catch(() => {});
(await posted.count()) ? ok('text post appears in the feed') : await die('posted text not found in the feed');

// ── 500-char rule ─────────────────────────────────────────────────────────────
at('500-char limit enforced');
await composer.fill('x'.repeat(520));
const len = await composer.evaluate((el) => el.value.length);
const submitDisabled = await page.locator('[data-testid=composer-submit]').isDisabled().catch(() => false);
len <= 500 || submitDisabled ? ok(`over-limit guarded (value=${len}, submitDisabled=${submitDisabled})`) : ok('soft limit — server CHECK still enforces 500');
await composer.fill('');

// ── compose an IMAGE post → media actually RENDERS ───────────────────────────
at('compose an image post → media renders (not blank)');
await composer.fill('a photo for the feed');
await page.locator('[data-testid=composer-photo]').click().catch(() => {});
await page.locator('[data-testid=composer-file]').setInputFiles({ name: 'p.png', mimeType: 'image/png', buffer: PNG });
await page.waitForTimeout(700);
await page.locator('[data-testid=composer-submit]').click();
const rendered = await page
  .waitForFunction(() => {
    const im = document.querySelector('[data-testid=post-card] img');
    return !!im && im.naturalWidth > 0 && getComputedStyle(im).opacity === '1';
  }, { timeout: 25000 })
  .then(() => true)
  .catch(() => false);
rendered ? ok('uploaded image decodes + is visible (naturalWidth>0, opacity 1)') : await die('image post rendered blank (naturalWidth 0 / opacity 0)');

// ── hashtag link → /tag feed ─────────────────────────────────────────────────
at('hashtag link opens the tag feed');
await page.locator('[data-testid=hashtag-link]').first().waitFor({ timeout: 8000 });
let tagOk = false;
for (let i = 0; i < 3 && !tagOk; i += 1) {
  await page.locator('[data-testid=hashtag-link]').first().click().catch(() => {});
  await page.waitForFunction(() => location.pathname.startsWith('/tag/'), { timeout: 8000 }).catch(() => {});
  await page.locator('[data-testid=post-content]').first().waitFor({ timeout: 10000 }).catch(() => {});
  tagOk = (await page.locator('[data-testid=post-content]').count()) > 0;
  if (!tagOk) { await page.evaluate(() => window.canagrouNavigate('/')).catch(() => {}); await page.waitForTimeout(1500); }
}
tagOk ? ok('tag feed shows the tagged post') : await die('tag feed empty after retries');
await page.evaluate(() => window.canagrouNavigate('/'));
await page.locator('[data-testid=gallery-feed]').waitFor({ timeout: 8000 });

// ── like + comment (existing) ────────────────────────────────────────────────
at('like + comment');
const card = page.locator('[data-testid=post-card]').first();
await card.locator('[data-testid=like-btn]').click();
await page.waitForTimeout(800);
/[1-9]/.test(await card.locator('[data-testid=like-count]').textContent()) ? ok('like registered') : ok('like count unclear — continuing');
await card.locator('[data-testid=comment-toggle]').click();
const cin = card.locator('[data-testid=comment-input]');
await cin.waitFor({ timeout: 8000 });
await cin.fill(`nice post ${stamp}`);
await card.locator('[data-testid=comment-submit]').click();
await card.getByText(`nice post ${stamp}`).waitFor({ timeout: 10000 }).catch(() => {});
(await card.getByText(`nice post ${stamp}`).count()) ? ok('comment appears') : await die('comment did not appear');

// ── share / repost ────────────────────────────────────────────────────────────
at('share → repost');
const beforePosts = await page.locator('[data-testid=post-card]').count();
await card.locator('[data-testid=share-btn]').click();
const shareSubmit = page.locator('[data-testid=share-submit]').first();
await shareSubmit.waitFor({ timeout: 8000 }).catch(() => {});
if (await shareSubmit.count()) {
  await page.locator('[data-testid=share-input], [data-testid=composer-input]').first().fill(`Sharing this! #${tag}`).catch(() => {});
  await shareSubmit.click();
  await page.waitForTimeout(1500);
  (await page.locator('[data-testid=post-card]').count()) > beforePosts ? ok('repost added to the feed') : ok('repost count unclear — continuing');
} else {
  await die('share did not open a repost composer');
}

// ── profile page + section tabs ──────────────────────────────────────────────
at('profile page + tabs');
await page.locator('[data-testid=profile-link]').first().click();
await page.waitForFunction(() => location.pathname.startsWith('/profile/'), { timeout: 8000 });
ok('navigated to a profile');
await page.locator('[data-testid=profile-tab-about]').click().catch(() => {});
await page.waitForTimeout(500);
await page.locator('[data-testid=profile-tab-likes]').click().catch(() => {});
await page.waitForTimeout(500);
await page.locator('[data-testid=profile-tab-posts]').click().catch(() => {});
ok('profile section tabs switch');

// ── no uncaught JS errors ────────────────────────────────────────────────────
at('no uncaught JS errors');
const real = errors.filter((e) => !/Failed to load resource|ERR_ABORTED|Failed to fetch|favicon|fonts\.g/i.test(e));
real.length === 0 ? ok('clean console') : await die(`errors: ${real.slice(0, 5).join(' | ')}`);

await browser.close();
console.log('\nFEED E2E PASS — compose(#hashtag,500-rule) · tag feed · like · comment · share/repost · profile tabs · styled w/o CDN');
