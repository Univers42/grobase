// browser-users.mjs — VOLUME-IS-REAL: /app/users lists HUNDREDS of real users (not
// a handful of demo rows), search filters the set, and pagination walks pages. Then
// the edit dialog flips a real user's role and the change round-trips across a
// reload, restoring the original role so the suite stays idempotent. --network host.

import { SPA, launch, realErrors, reporter, login, shot } from './_lib.mjs';

const { browser, page, errors, logs } = await launch();
const { at, ok, die } = reporter(page, browser);

/** totalUsers reads the "<n> users" total the Pager prints under the table. */
async function totalUsers() {
  const txt = (await page.locator('.pt-4 span').first().textContent().catch(() => '')) || '';
  const m = txt.match(/(\d[\d,]*)\s+users?/i);
  return m ? Number(m[1].replace(/,/g, '')) : 0;
}

/** firstRow returns the {name,email} of the first table row (real data probe). The
 *  identity cell renders the display name above the email, so the first text line
 *  that isn't the avatar-initials/email is the name. */
async function firstRow() {
  const tr = page.locator('tbody tr').first();
  const email = ((await tr.innerText().catch(() => '')).match(/[\w.+-]+@[\w.-]+/) || [''])[0];
  const name = ((await tr.locator('td').first().innerText().catch(() => '')) || '')
    .split('\n')
    .map((s) => s.trim())
    .find((s) => s && !s.includes('@') && /\s/.test(s) && s.length > 3) || '';
  return { name, email };
}

/** firstRowEmail returns just the email shown in the first table row. */
async function firstRowEmail() {
  return (await firstRow()).email;
}

/** revealUser server-side searches by display name so the target row is on the
 *  visible page regardless of pagination/sort order, then waits for its row. */
async function revealUser({ name, email }) {
  const search = page.locator('input[aria-label="Search users by name"]');
  await search.fill(name);
  await page.waitForTimeout(1000);
  await page.locator('tbody tr', { hasText: email }).first().waitFor({ timeout: 10000 });
}

/** roleBadgeFor reveals the target row then returns its role badge text. */
async function roleBadgeFor(target) {
  await revealUser(target);
  const row = page.locator('tbody tr', { hasText: target.email }).first();
  const badges = await row.locator('span').allTextContents();
  return badges.map((t) => t.trim()).find((t) => ['admin', 'staff', 'customer'].includes(t)) || '';
}

at('admin login → Users');
await login(page);
await page.goto(`${SPA}/app/users`, { waitUntil: 'domcontentloaded' });
await page.locator('table').waitFor({ timeout: 12000 });
const pageRows = await page.locator('tbody tr').count();
const total = await totalUsers();
total >= 100
  ? ok(`Users table reports ${total} REAL users (showing ${pageRows}/page) — not a demo handful`)
  : await die(`expected hundreds of users, the UI shows only ${total}`, logs);

at('pagination: Next walks to page 2 with a fresh set of rows');
const page1Email = await firstRowEmail();
await page.getByRole('button', { name: 'Next' }).click();
await page.waitForTimeout(800);
const pageLabel = (await page.locator('.pt-4 .tabular-nums').first().textContent().catch(() => '')) || '';
const page2Email = await firstRowEmail();
/^2 \//.test(pageLabel.trim()) && page2Email && page2Email !== page1Email
  ? ok(`paged to "${pageLabel.trim()}" — page 2 first user ${page2Email} differs from page 1 (${page1Email})`)
  : await die(`pagination did not advance (label="${pageLabel.trim()}", p1=${page1Email}, p2=${page2Email})`, logs);
await page.getByRole('button', { name: 'Prev' }).click();
await page.waitForTimeout(700);

at('search narrows the real set (by name substring "a")');
const search = page.locator('input[aria-label="Search users by name"]');
await search.fill('a');
await page.waitForTimeout(1100);
const filtered = await totalUsers();
filtered > 0 && filtered < total
  ? ok(`search "a" narrowed ${total} → ${filtered} users (server-side ilike on name)`)
  : await die(`search did not narrow the set (was ${total}, got ${filtered})`, logs);
await search.fill('');
await page.waitForTimeout(700);

at('screenshot the volume Users list');
await shot(page, 'users');
ok('captured users.png');

at('edit dialog flips a real user role + round-trips across reload');
const target = await firstRow();
const before = await roleBadgeFor(target);
ok(`picked real user ${target.name} <${target.email}> — role before = "${before}"`);
const next = before === 'staff' ? 'customer' : 'staff';
await page.locator('tbody tr', { hasText: target.email }).first().getByRole('button', { name: 'Edit' }).click();
await page.getByRole('heading', { name: 'Edit user' }).waitFor({ timeout: 8000 });
await page.locator('[role="dialog"] select').first().selectOption(next);
await page.getByRole('button', { name: 'Save changes' }).click();
await page.getByText('User updated').waitFor({ timeout: 10000 }).catch(() => {});
await page.reload({ waitUntil: 'domcontentloaded' });
await page.locator('table').waitFor({ timeout: 12000 });
const after = await roleBadgeFor(target);
after === next
  ? ok(`reload confirms ${target.email} role = "${after}" (persisted to app_users)`)
  : await die(`role did not round-trip: want "${next}", got "${after}"`, logs);

at('restore the original role');
await page.locator('tbody tr', { hasText: target.email }).first().getByRole('button', { name: 'Edit' }).click();
await page.getByRole('heading', { name: 'Edit user' }).waitFor({ timeout: 8000 });
await page.locator('[role="dialog"] select').first().selectOption(before);
await page.getByRole('button', { name: 'Save changes' }).click();
await page.getByText('User updated').waitFor({ timeout: 10000 }).catch(() => {});
ok(`restored ${target.email} role → "${before}"`);

at('clean console');
const real = realErrors(errors);
real.length === 0 ? ok('no console.error / pageerror') : await die(`browser errors:\n   ${real.join('\n   ')}`, logs);

await browser.close();
console.log(`\nUSERS PASS — ${total} real users · pagination · server-side search · edit role round-trip (restored)`);
