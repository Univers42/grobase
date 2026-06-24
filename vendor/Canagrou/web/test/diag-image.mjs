// diag-image.mjs — register, post an image, and inspect the feed <img>: is the
// src a blob, did it decode (naturalWidth), is it visible (opacity), does it
// carry the .loaded class? Pinpoints why media doesn't render.
import { chromium } from 'playwright';
const SPA = process.env.SPA_URL || 'https://localhost:8123';
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);
const browser = await chromium.launch({ args: ['--no-sandbox'] });
const page = await (await browser.newContext({ ignoreHTTPSErrors: true })).newPage();
const errs = [];
page.on('console', (m) => m.type() === 'error' && errs.push(m.text()));
const st = Date.now();
await page.goto(`${SPA}/register`, { waitUntil: 'domcontentloaded' });
await page.locator('[data-testid=auth-email]').fill(`img_${st}@canagrou.local`);
await page.locator('[data-testid=auth-username]').fill(`img_${st}`.slice(0, 18));
await page.locator('[data-testid=auth-password]').fill('Imgtest!42pass');
await page.locator('[data-testid=auth-confirm]').fill('Imgtest!42pass');
await page.locator('[data-testid=auth-submit]').click();
await page.waitForFunction(() => location.pathname === '/' && document.querySelector('[data-testid=gallery-feed]'), { timeout: 20000 });
await page.locator('[data-testid=composer-input]').fill('image render test');
await page.locator('[data-testid=composer-photo]').click().catch(() => {});
await page.locator('[data-testid=composer-file]').setInputFiles({ name: 'p.png', mimeType: 'image/png', buffer: PNG });
await page.waitForTimeout(700);
await page.locator('[data-testid=composer-submit]').click();
await page.locator('[data-testid=post-card]').first().waitFor({ timeout: 12000 });
await page.waitForTimeout(4000); // let realtime refreshes settle + blob resolve
const info = await page.evaluate(async () => {
  const cfg = window.__BAAS__;
  const headers = { apikey: cfg.anonKey, 'X-Baas-Api-Key': cfg.apiKey, 'Content-Type': 'application/json' };
  const list = await (await fetch(`${cfg.url}/query/v1/${cfg.dbId}/tables/posts`, {
    method: 'POST', headers, body: JSON.stringify({ op: 'list', sort: { created_at: 'desc' }, limit: 1 }),
  })).json();
  const post = (list.rows || [])[0] || {};
  let fetchResult = '(no key)';
  if (post.image_key) {
    try {
      const r = await fetch(`${cfg.url}/storage/v1/object/${cfg.storageBucket}/${post.image_key}`, {
        headers: { apikey: cfg.anonKey, Authorization: `Bearer ${cfg.storageToken}` },
      });
      const blob = await r.blob();
      fetchResult = `status=${r.status} size=${blob.size} type=${blob.type}`;
    } catch (e) {
      fetchResult = 'ERR ' + String(e);
    }
  }
  const imgs = [...document.querySelectorAll('[data-testid=post-card] img')].map((im) => ({
    cls: im.className.slice(0, 24),
    src: (im.getAttribute('src') || '').slice(0, 24),
    nW: im.naturalWidth,
    op: getComputedStyle(im).opacity,
    loaded: im.classList.contains('loaded'),
  }));
  return { postImageKey: post.image_key || null, storageFetch: fetchResult, imgs };
});
console.log('DIAG:', JSON.stringify(info, null, 1));
console.log('console errors:', errs.slice(0, 6));
await page.screenshot({ path: '/web/test/img-diag.png', fullPage: true }).catch(() => {});
await browser.close();
