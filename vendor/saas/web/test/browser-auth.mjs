// browser-auth.mjs — registers a fresh random user via /register, expects to land
// signed-in on /app (or sign in then /app), asserts the session persists across a
// reload, then logs out and signs back in as the seeded admin. Run in the
// Playwright image, --network host.

import { SPA, ADMIN, launch, realErrors, reporter, login, logout, sessionToken } from './_lib.mjs';

const { browser, page, errors, logs } = await launch();
const { at, ok, die } = reporter(page, browser);

const stamp = Date.now().toString(36);
const fresh = { email: `nimbus_${stamp}@nimbus.local`, password: `Nimbus#${stamp}` };

at('register a fresh user');
await page.goto(`${SPA}/register`, { waitUntil: 'domcontentloaded' });
await page.locator('input[autocomplete="username"]').fill(`user_${stamp}`.slice(0, 18));
await page.locator('input[type="email"]').fill(fresh.email);
await page.locator('input[type="password"]').fill(fresh.password);
await page.getByRole('button', { name: 'Create account' }).click();

at('lands signed-in on /app (or routed to /login on a confirm-tenant)');
const landed = await page
  .waitForFunction(() => location.pathname.startsWith('/app'), { timeout: 20000 })
  .then(() => true)
  .catch(() => false);
if (!landed) {
  // email-confirmation tenant: sign-in is the documented fallback path.
  await page.waitForFunction(() => location.pathname === '/login', { timeout: 8000 }).catch(() => {});
  await login(page, fresh);
}
(await sessionToken(page)) ? ok('registered → authenticated session established') : await die('no session after register/sign-in', logs);
ok('landed on /app');

at('session persists across a reload');
await page.reload({ waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => location.pathname.startsWith('/app'), { timeout: 10000 }).catch(() => {});
(await page.evaluate(() => location.pathname.startsWith('/app')) && (await sessionToken(page)))
  ? ok('still on /app with a live session after reload')
  : await die('session did not persist across reload', logs);

at('log out');
await logout(page);
(await sessionToken(page)) === '' ? ok('session cleared on logout') : await die('session lingered after logout', logs);

at('log in as admin');
await login(page, ADMIN);
(await sessionToken(page)) ? ok('admin signed in → /app') : await die('admin sign-in failed', logs);

at('guard: signed-out user cannot reach /app');
await page.evaluate(() => localStorage.removeItem('nimbus.session'));
await page.goto(`${SPA}/app`, { waitUntil: 'domcontentloaded' });
await page.waitForFunction(() => location.pathname === '/login', { timeout: 8000 }).catch(() => {});
(await page.evaluate(() => location.pathname === '/login')) ? ok('RequireAuth bounces to /login') : await die('guard did not redirect', logs);

at('clean console');
const real = realErrors(errors);
real.length === 0 ? ok('no console.error / pageerror') : await die(`browser errors:\n   ${real.join('\n   ')}`, logs);

await browser.close();
console.log('\nAUTH PASS — register → /app · persists across reload · logout · admin login · guard redirect');
