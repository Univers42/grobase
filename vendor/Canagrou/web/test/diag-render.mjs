import { chromium } from 'playwright';
const SPA = process.env.SPA_URL || 'https://localhost:8123';
const browser = await chromium.launch({ args: ['--no-sandbox'] });
const page = await (await browser.newContext({ ignoreHTTPSErrors: true })).newPage();
const errs = [];
page.on('console', (m) => m.type() === 'error' && errs.push(m.text()));
await page.goto(SPA, { waitUntil: 'domcontentloaded' });
await page.locator('[data-testid=post-card]').first().waitFor({ timeout: 15000 }).catch(() => {});
await page.waitForTimeout(6000);
const info = await page.evaluate(() => {
  const cards = document.querySelectorAll('[data-testid=post-card]').length;
  const imgs = [...document.querySelectorAll('[data-testid=post-card] img')].map((im) => ({
    src: (im.getAttribute('src') || '').slice(0, 14), nW: im.naturalWidth, op: getComputedStyle(im).opacity, loaded: im.classList.contains('loaded'),
  }));
  return { cards, imgCount: imgs.length, imgs: imgs.slice(0, 8) };
});
console.log('RENDER:', JSON.stringify(info));
console.log('errs:', [...new Set(errs)].slice(0, 4));
await page.screenshot({ path: '/web/test/render.png', fullPage: true }).catch(() => {});
await browser.close();
