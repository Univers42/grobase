// browser-users.mjs — /app/users lists users, search filters, the edit dialog
// changes a role, save round-trips (reload shows the new value). Restores the
// original role at the end so the suite is idempotent. Run --network host.

import { SPA, launch, realErrors, reporter, login, shot } from './_lib.mjs';

const { browser, page, errors, logs } = await launch();
const { at, ok, die } = reporter(page, browser);

/** roleBadgeFor returns the role badge text of the row matching an email. */
async function roleBadgeFor(email) {
  const row = page.locator('tbody tr', { hasText: email });
  await row.first().waitFor({ timeout: 10000 });
  // role/status badges are the small pills in the row; read all, pick the role one.
  const badges = await row.first().locator('span').allTextContents();
  return badges.find((t) => ['admin', 'staff', 'customer'].includes(t.trim())) || '';
}

at('admin login → Users');
await login(page);
await page.goto(`${SPA}/app/users`, { waitUntil: 'domcontentloaded' });
await page.locator('table').waitFor({ timeout: 12000 });
const total = await page.locator('tbody tr').count();
total >= 1 ? ok(`users table lists ${total} row(s)`) : await die('users table empty', logs);

at('search filters the list');
await page.locator('input[aria-label="Search users by name"]').fill('Bob');
await page.waitForTimeout(900);
const filtered = await page.locator('tbody tr').count();
const hasBob = await page.locator('tbody tr', { hasText: 'bob@nimbus.local' }).count();
hasBob >= 1 && filtered <= total ? ok(`search "Bob" → ${filtered} row(s) incl. bob`) : await die(`search did not filter (got ${filtered}, bob=${hasBob})`, logs);
await page.locator('input[aria-label="Search users by name"]').fill('');
await page.waitForTimeout(700);

at('open edit dialog for carol + flip role');
const target = 'carol@nimbus.local';
const before = await roleBadgeFor(target);
ok(`carol role before = "${before}"`);
const next = before === 'staff' ? 'admin' : 'staff';
await page.locator('tbody tr', { hasText: target }).first().getByRole('button', { name: 'Edit' }).click();
await page.getByRole('heading', { name: 'Edit user' }).waitFor({ timeout: 8000 });
// the first select in the dialog is Role.
await page.locator('[role="dialog"] select').first().selectOption(next);
await page.getByRole('button', { name: 'Save changes' }).click();
await page.getByText('User updated').waitFor({ timeout: 10000 }).catch(() => {});
ok(`saved carol role → "${next}"`);

at('round-trip: reload shows the new role');
await page.reload({ waitUntil: 'domcontentloaded' });
const after = await roleBadgeFor(target);
after === next ? ok(`reload confirms carol role = "${after}" (persisted)`) : await die(`role did not round-trip: want "${next}", got "${after}"`, logs);

at('screenshot users');
await shot(page, 'users');

at('restore carol role to original');
await page.locator('tbody tr', { hasText: target }).first().getByRole('button', { name: 'Edit' }).click();
await page.getByRole('heading', { name: 'Edit user' }).waitFor({ timeout: 8000 });
await page.locator('[role="dialog"] select').first().selectOption(before);
await page.getByRole('button', { name: 'Save changes' }).click();
await page.getByText('User updated').waitFor({ timeout: 10000 }).catch(() => {});
ok(`restored carol role → "${before}"`);

at('clean console');
const real = realErrors(errors);
real.length === 0 ? ok('no console.error / pageerror') : await die(`browser errors:\n   ${real.join('\n   ')}`, logs);

await browser.close();
console.log('\nUSERS PASS — list · search filter · edit dialog · role round-trip (restored)');
