// diag-cdn.mjs — reproduce "style is really wrong": load the SPA with the
// Tailwind CDN BLOCKED (as a CSP/offline/network might) and screenshot.
import { chromium } from 'playwright';
const SPA = process.env.SPA_URL || 'https://localhost:8123';
const browser = await chromium.launch({ args: ['--no-sandbox'] });
const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
const page = await ctx.newPage();
let cdnBlocked = false;
await page.route(/cdn\.tailwindcss\.com/, (r) => { cdnBlocked = true; r.abort(); });
await page.goto(`${SPA}/register`, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(1500);
await page.screenshot({ path: '/web/test/cdn-blocked.png', fullPage: true });
console.log('CDN requested (and blocked):', cdnBlocked);
await browser.close();
