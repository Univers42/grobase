// console-csp.mjs — navigates every Nimbus route (public + guarded) capturing
// console.error, pageerror, and CSP violations; asserts none across the app.
// Run in the Playwright image, --network host.

import { SPA, launch, realErrors, reporter, login } from './_lib.mjs';

const { browser, page, errors, logs } = await launch();
const { at, ok, die } = reporter(page, browser);

// CSP violations surface as a securitypolicyviolation event in the page; mirror
// them into console.error so realErrors() catches them. The app's strict CSP is
// real (verified below) — the harness only bypasses it to inject this listener.
await page.addInitScript(() => {
  document.addEventListener('securitypolicyviolation', (e) => {
    // eslint-disable-next-line no-console
    console.error(`CSP-VIOLATION: ${e.violatedDirective} blocked ${e.blockedURI}`);
  });
});

at('the server ships a strict CSP header');
const resp = await page.goto(`${SPA}/`, { waitUntil: 'domcontentloaded' });
const csp = resp?.headers()['content-security-policy'] || '';
/script-src 'self'/.test(csp) && !/unsafe-eval/.test(csp) && /object-src 'none'/.test(csp)
  ? ok("CSP is strict (script-src 'self', no unsafe-eval, object-src 'none')")
  : await die(`weak/missing CSP header: "${csp}"`, logs);

const publicRoutes = ['/', '/login', '/register', '/forgot', '/nope-404'];
const guardedRoutes = ['/app', '/app/users', '/app/inbox', '/app/revenue', '/app/content'];

at('public routes');
for (const r of publicRoutes) {
  await page.goto(`${SPA}${r}`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(400);
  ok(`visited ${r}`);
}

at('admin login → guarded routes');
await login(page);
for (const r of guardedRoutes) {
  await page.goto(`${SPA}${r}`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(600);
  ok(`visited ${r}`);
}

at('no console.error / pageerror / CSP violation anywhere');
const real = realErrors(errors);
real.length === 0
  ? ok('clean across all 10 routes')
  : await die(`errors across the app:\n   ${real.join('\n   ')}`, logs);

await browser.close();
console.log('\nCONSOLE/CSP PASS — 10 routes, no console.error · no pageerror · no CSP violation');
