import { chromium } from 'playwright';
const SPA = process.env.SPA_URL || 'https://localhost:8123';
const browser = await chromium.launch({ args: ['--no-sandbox'] });
const page = await (await browser.newContext({ ignoreHTTPSErrors: true })).newPage();
await page.goto(SPA, { waitUntil: 'domcontentloaded' });
await page.locator('[data-testid=post-card]').first().waitFor({ timeout: 15000 }).catch(() => {});
// scroll through the feed to trigger lazy-load, then settle
for (let y = 0; y < 6; y++) { await page.mouse.wheel(0, 900); await page.waitForTimeout(900); }
await page.waitForTimeout(3000);
const r = await page.evaluate(() => {
  const imgs = [...document.querySelectorAll('[data-testid=post-card] img')];
  const loaded = imgs.filter((im) => im.naturalWidth > 0 && getComputedStyle(im).opacity === '1').length;
  const maxW = Math.max(0, ...imgs.map((im) => im.naturalWidth));
  return { total: imgs.length, loaded, biggestImageWidth: maxW };
});
console.log('SCROLL-RENDER:', JSON.stringify(r));
await browser.close();
