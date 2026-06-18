// browser-revenue-acid.mjs — THE money flow, MONEY-IS-REAL. Reads the three KPI
// money tiles the UI shows (Posted revenue, Revenue balance, Customer balances) and
// the ledger leg count, records a valid payment, and asserts all three figures move
// by the amount, a balanced ledger pair appears, AND the move PERSISTS across a full
// reload (it is committed, not local state). Then forces a duplicate-reference
// payment and asserts an error toast appears AND every figure is UNCHANGED (the ACID
// rollback, visible in the UI). Screenshots before + after. Run --network host.

import { SPA, launch, realErrors, reporter, login, shot } from './_lib.mjs';

const { browser, page, errors, logs } = await launch();
const { at, ok, die } = reporter(page, browser);

/** kpiCents reads one RevenueSummary money tile ("$X,XXX.XX" → integer cents) by
 *  its label. The label span is icon-led (" Posted revenue"), so match the label
 *  as a substring; the tile is the GlassCard wrapping that label + its value. */
async function kpiCents(label) {
  const tile = page.locator('div', { has: page.getByText(label, { exact: false }) }).last();
  await tile.locator('span.text-2xl.font-semibold').first().waitFor({ timeout: 10000 });
  const txt = (await tile.locator('span.text-2xl.font-semibold').first().textContent()) || '';
  return Math.round(parseFloat(txt.replace(/[^0-9.-]/g, '')) * 100);
}

/** money snapshots the three live money figures the UI displays. */
async function money() {
  return {
    posted: await kpiCents('Posted revenue'),
    revenue: await kpiCents('Revenue balance'),
    customers: await kpiCents('Customer balances'),
  };
}

/** ledgerCard locates the Ledger panel (newest legs first, capped at 20). */
function ledgerCard() {
  return page.locator('div', { has: page.getByRole('heading', { name: 'Ledger' }) }).last();
}

/** topLegAmounts returns the formatted amounts of the two newest ledger legs. The
 *  panel is capped at 20 and already full, so a new payment's balanced pair proves
 *  itself by appearing at the TOP (id desc), not by growing the count. */
async function topLegAmounts() {
  const legs = ledgerCard().locator('ul.space-y-2 > li');
  return [
    ((await legs.nth(0).innerText().catch(() => '')) || '').replace(/\s+/g, ' ').trim(),
    ((await legs.nth(1).innerText().catch(() => '')) || '').replace(/\s+/g, ' ').trim(),
  ];
}

/** waitToast polls for the first toast text containing `needle` (toasts auto-
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

/** openRevenue navigates to /app/revenue and waits for the money tiles to render. */
async function openRevenue() {
  await page.goto(`${SPA}/app/revenue`, { waitUntil: 'domcontentloaded' });
  await page.getByRole('heading', { name: /Revenue/ }).waitFor({ timeout: 12000 });
  await page.getByText('Posted revenue', { exact: false }).first().waitFor({ timeout: 12000 });
  await page.waitForTimeout(1200);
}

at('admin login → Revenue');
await login(page);
await openRevenue();

const m0 = await money();
const top0 = await topLegAmounts();
ok(`money before — posted=$${(m0.posted / 100).toFixed(2)} revenueBal=$${(m0.revenue / 100).toFixed(2)} customerBal=$${(m0.customers / 100).toFixed(2)}; top ledger legs=${JSON.stringify(top0)}`);
await shot(page, 'revenue-before');

// ── valid payment: posted+rev rise, customer falls, a balanced ledger pair lands ─
at('record a valid payment on the first customer account');
// a unique sub-dollar amount per run so the new ledger pair is distinguishable
// from any pair a prior run left at the top of the (capped) panel.
const AMOUNT = 3 + (Date.now() % 97) / 100;
const cents = Math.round(AMOUNT * 100);
await page.getByRole('button', { name: 'Record payment' }).click();
await page.getByRole('heading', { name: 'Record payment' }).waitFor({ timeout: 8000 });
await page.locator('input[type="number"]').fill(String(AMOUNT));
const goodRef = `pw_ok_${Date.now().toString(36)}`;
await page.locator('[role="dialog"] input').last().fill(goodRef);
await page.locator('[role="dialog"]').getByRole('button', { name: 'Record payment' }).click();

at('success toast confirms the atomic commit');
(await waitToast('Payment recorded atomically'))
  ? ok('toast: "Payment recorded atomically"')
  : await die('no success toast after a valid payment', logs);

at('all three money figures moved by the amount + a balanced ledger pair landed');
await page.waitForTimeout(1300);
const m1 = await money();
const moved = m1.posted === m0.posted + cents && m1.revenue === m0.revenue + cents && m1.customers === m0.customers - cents;
moved
  ? ok(`posted ${m0.posted}→${m1.posted} (+${cents}), revenueBal +${cents}, customerBal −${cents} — double-entry moved`)
  : await die(`figures did not move correctly: posted ${m0.posted}→${m1.posted}, rev ${m0.revenue}→${m1.revenue}, cust ${m0.customers}→${m1.customers} (want ±${cents})`, logs);
const top1 = await topLegAmounts();
const amt = `$${AMOUNT.toFixed(2)}`;
const newPairAtTop = top1.every((leg) => leg.includes(amt)) && top1.some((l) => /credit/i.test(l)) && top1.some((l) => /debit/i.test(l)) && JSON.stringify(top1) !== JSON.stringify(top0);
newPairAtTop
  ? ok(`new balanced ledger pair at top: ${JSON.stringify(top1)} (debit ${amt} + credit ${amt})`)
  : await die(`no fresh balanced ${amt} ledger pair at the top of the panel (top=${JSON.stringify(top1)})`, logs);
await shot(page, 'revenue-after-commit');

at('the commit PERSISTS across a full reload (it is durable, not local state)');
await openRevenue();
const mReload = await money();
mReload.posted === m1.posted && mReload.revenue === m1.revenue && mReload.customers === m1.customers
  ? ok(`reload re-read the committed figures: posted=$${(mReload.posted / 100).toFixed(2)} revenueBal=$${(mReload.revenue / 100).toFixed(2)}`)
  : await die(`figures did not persist across reload: ${JSON.stringify(m1)} vs ${JSON.stringify(mReload)}`, logs);

// ── forced failure: duplicate reference → rollback, every figure UNCHANGED ──────
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

at('every money figure is UNCHANGED (the visible rollback)');
await page.keyboard.press('Escape').catch(() => {});
await page.waitForTimeout(1300);
const m2 = await money();
m2.posted === m1.posted && m2.revenue === m1.revenue && m2.customers === m1.customers
  ? ok(`rollback held: posted stays ${m2.posted}, revenueBal ${m2.revenue}, customerBal ${m2.customers}`)
  : await die(`ROLLBACK BROKEN: posted ${m1.posted}→${m2.posted}, rev ${m1.revenue}→${m2.revenue}, cust ${m1.customers}→${m2.customers}`, logs);
await shot(page, 'revenue-after-rollback');

at('clean console (a handled 409 is not a pageerror)');
const real = realErrors(errors);
real.length === 0 ? ok('no console.error / pageerror') : await die(`browser errors:\n   ${real.join('\n   ')}`, logs);

await browser.close();
console.log(`\nREVENUE ACID PASS — commit moved $${AMOUNT} (posted+, revenue+, customer−, ledger pair) and PERSISTED across reload; duplicate-ref rolled back leaving every figure unchanged`);
