// browser-revenue-acid.mjs — THE money flow. Reads the customer + revenue balances
// shown in the UI, records a valid payment, and asserts BOTH balances moved by the
// amount AND a new ledger leg appears. Then forces a duplicate-reference payment
// and asserts an error toast appears AND the balances are UNCHANGED (the ACID
// rollback, visible in the UI). Screenshots before + after. Run --network host.

import { SPA, launch, realErrors, reporter, login, shot } from './_lib.mjs';

const { browser, page, errors, logs } = await launch();
const { at, ok, die } = reporter(page, browser);

/** balanceFor reads the AccountsPanel balance ($X,XXX.XX → cents) for a kind. */
async function balanceFor(kind) {
  const row = page.locator('ul.space-y-2 > li', { has: page.locator('span', { hasText: new RegExp(`^${kind}$`) }) }).first();
  await row.waitFor({ timeout: 10000 });
  const txt = (await row.locator('span.font-semibold.tabular-nums').textContent()) || '';
  return Math.round(parseFloat(txt.replace(/[^0-9.-]/g, '')) * 100);
}

/** ledgerCount returns how many ledger legs are listed in the Ledger panel. The
 *  Ledger card is the one whose heading is "Ledger"; its leg rows are its <li>s. */
async function ledgerCount() {
  const card = page.locator('div', { has: page.getByRole('heading', { name: 'Ledger' }) }).last();
  return card.locator('ul.space-y-2 > li').count();
}

/** waitToast resolves to the first toast text containing `needle` (toasts auto-
 *  dismiss after ~4.5s, so poll rather than wait-then-read). */
async function waitToast(needle, ms = 12000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const texts = await page.locator('[role="status"]').allTextContents();
    const hit = texts.find((t) => t.includes(needle));
    if (hit) return hit;
    await page.waitForTimeout(150);
  }
  return '';
}

at('admin login → Revenue');
await login(page);
await page.goto(`${SPA}/app/revenue`, { waitUntil: 'domcontentloaded' });
await page.getByRole('heading', { name: /Revenue/ }).waitFor({ timeout: 12000 });
await page.locator('ul.space-y-2 > li').first().waitFor({ timeout: 12000 });

const cust0 = await balanceFor('customer');
const rev0 = await balanceFor('revenue');
const ledger0 = await ledgerCount();
ok(`balances before — customer=$${(cust0 / 100).toFixed(2)} revenue=$${(rev0 / 100).toFixed(2)}; ledger legs=${ledger0}`);
await shot(page, 'revenue-before');

// ── valid payment: both balances move, a ledger leg appears ──────────────────
at('record a valid payment ($3.50)');
const AMOUNT = 3.5;
const cents = Math.round(AMOUNT * 100);
await page.getByRole('button', { name: 'Record payment' }).click();
await page.getByRole('heading', { name: 'Record payment' }).waitFor({ timeout: 8000 });
await page.locator('input[type="number"]').fill(String(AMOUNT));
const goodRef = `pw_ok_${Date.now().toString(36)}`;
const refInput = page.locator('[role="dialog"] input').last();
await refInput.fill(goodRef);
await page.locator('[role="dialog"]').getByRole('button', { name: 'Record payment' }).click();

at('success toast confirms the atomic commit');
(await waitToast('Payment recorded atomically'))
  ? ok('toast: "Payment recorded atomically"')
  : await die('no success toast after a valid payment', logs);

at('balances moved by the amount + a ledger leg appeared');
await page.waitForTimeout(1200);
const cust1 = await balanceFor('customer');
const rev1 = await balanceFor('revenue');
const ledger1 = await ledgerCount();
const moved = cust1 === cust0 - cents && rev1 === rev0 + cents;
moved
  ? ok(`customer ${cust0}→${cust1} (−${cents}), revenue ${rev0}→${rev1} (+${cents}) — double-entry moved`)
  : await die(`balances did not move correctly: customer ${cust0}→${cust1} (want ${cust0 - cents}), revenue ${rev0}→${rev1} (want ${rev0 + cents})`, logs);
ledger1 > ledger0
  ? ok(`ledger grew ${ledger0}→${ledger1} leg(s)`)
  : await die(`no new ledger leg (was ${ledger0}, now ${ledger1})`, logs);
await shot(page, 'revenue-after-commit');

// ── forced failure: duplicate reference → rollback, balances UNCHANGED ────────
at('force a failing payment (duplicate reference) → ACID rollback');
await page.getByRole('button', { name: 'Record payment' }).click();
await page.getByRole('heading', { name: 'Record payment' }).waitFor({ timeout: 8000 });
await page.locator('input[type="number"]').fill('9.99');
await page.locator('[role="dialog"] input').last().fill(goodRef); // reuse the committed ref → UNIQUE violation
await page.locator('[role="dialog"]').getByRole('button', { name: 'Record payment' }).click();

at('error toast appears');
(await waitToast('Rolled back'))
  ? ok('toast: "Rolled back — balances unchanged"')
  : await die('no error toast on the duplicate-reference payment', logs);

at('balances are UNCHANGED (the visible rollback)');
// close any open dialog so the panel re-reads.
await page.keyboard.press('Escape').catch(() => {});
await page.waitForTimeout(1200);
const cust2 = await balanceFor('customer');
const rev2 = await balanceFor('revenue');
cust2 === cust1 && rev2 === rev1
  ? ok(`rollback held: customer stays ${cust2}, revenue stays ${rev2}`)
  : await die(`ROLLBACK BROKEN: customer ${cust1}→${cust2}, revenue ${rev1}→${rev2}`, logs);
await shot(page, 'revenue-after-rollback');

at('clean console (a handled 409 is not a pageerror)');
const real = realErrors(errors);
real.length === 0 ? ok('no console.error / pageerror') : await die(`browser errors:\n   ${real.join('\n   ')}`, logs);

await browser.close();
console.log(`\nREVENUE ACID PASS — commit moved $${AMOUNT} (customer −, revenue +, ledger leg added); duplicate-ref left both balances unchanged`);
