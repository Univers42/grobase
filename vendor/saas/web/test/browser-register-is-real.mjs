// browser-register-is-real.mjs — THE headline proof: a self-service /register signup
// must become REAL console data. Registers a brand-new unique user through the UI,
// then signs in as the admin and confirms THAT user now appears in the Users list
// (the console reads app_users, so this proves the GoTrue→app_users provisioning
// gap is closed). Records the live total user count. Run --network host.

import { SPA, ADMIN, launch, realErrors, reporter, login, logout, shot } from './_lib.mjs';

const { browser, page, errors, logs } = await launch();
const { at, ok, die } = reporter(page, browser);

const stamp = Date.now().toString(36);
const fresh = {
  username: `newbie_${stamp}`.slice(0, 18),
  email: `newbie_${stamp}@nimbus.local`,
  password: `Nimbus#${stamp}`,
};

/** totalUsers reads the "<n> users" total the Pager prints under the table. */
async function totalUsers() {
  const txt = (await page.locator('.pt-4 span').first().textContent().catch(() => '')) || '';
  const m = txt.match(/(\d[\d,]*)\s+users?/i);
  return m ? Number(m[1].replace(/,/g, '')) : 0;
}

at('register a brand-new unique user via /register');
await page.goto(`${SPA}/register`, { waitUntil: 'domcontentloaded' });
await page.locator('input[autocomplete="username"]').fill(fresh.username);
await page.locator('input[type="email"]').fill(fresh.email);
await page.locator('input[type="password"]').fill(fresh.password);
await page.getByRole('button', { name: 'Create account' }).click();

at('the signup resolves (session on /app, or a confirm-tenant routes to /login)');
const landed = await page
  .waitForFunction(() => location.pathname.startsWith('/app'), { timeout: 20000 })
  .then(() => true)
  .catch(() => false);
if (!landed) await page.waitForFunction(() => location.pathname === '/login', { timeout: 8000 }).catch(() => {});
ok(`registered ${fresh.email} (username "${fresh.username}")`);

at('log out the new user, then sign in as admin');
await logout(page);
await login(page, ADMIN);
ok('admin signed in');

at('open Users and read the live total');
await page.goto(`${SPA}/app/users`, { waitUntil: 'domcontentloaded' });
await page.locator('table').waitFor({ timeout: 12000 });
const total = await totalUsers();
total >= 100 ? ok(`Users list reports ${total} real users`) : await die(`Users total looks unseeded (${total})`, logs);

at('search the admin Users list for the freshly-registered user');
const search = page.locator('input[aria-label="Search users by name"]');
await search.fill(fresh.username);
await page.waitForTimeout(1100);
const row = page.locator('tbody tr', { hasText: fresh.email });
const found = await row.count();
found >= 1
  ? ok(`THE PROOF: the new signup "${fresh.username}" <${fresh.email}> appears among ${total} console users`)
  : await die(`registered user did NOT appear in the admin Users list (the gap is NOT closed)`, logs);

at('screenshot the admin Users list showing the new user');
await shot(page, 'register-is-real');
ok('captured register-is-real.png');

at('clean console');
const real = realErrors(errors);
real.length === 0 ? ok('no console.error / pageerror') : await die(`browser errors:\n   ${real.join('\n   ')}`, logs);

await browser.close();
console.log(`\nREGISTER-IS-REAL PASS — a fresh /register signup became real app_users data: admin sees "${fresh.username}" among ${total} users`);
