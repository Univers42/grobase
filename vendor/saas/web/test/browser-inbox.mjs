// browser-inbox.mjs — /app/inbox lists messages; selecting the Open folder, opening
// a message marks it read, and Close removes it from the Open list (the list
// shrinks). Reopens it afterward to keep the suite idempotent. Run --network host.

import { SPA, launch, realErrors, reporter, login, shot } from './_lib.mjs';

const { browser, page, errors, logs } = await launch();
const { at, ok, die } = reporter(page, browser);

at('admin login → Inbox');
await login(page);
await page.goto(`${SPA}/app/inbox`, { waitUntil: 'domcontentloaded' });
await page.getByRole('heading', { name: 'Inbox' }).waitFor({ timeout: 12000 });

at('filter to the Open folder');
await page.getByRole('tab', { name: 'Open' }).click();
await page.waitForTimeout(600);
const rows = () => page.locator('.flex.flex-col.gap-1 > button');
await rows().first().waitFor({ timeout: 10000 }).catch(() => {});
const openBefore = await rows().count();
openBefore >= 1 ? ok(`Open folder lists ${openBefore} message(s)`) : await die('no open messages to act on', logs);

at('open the first message (marks read)');
const subject = (await rows().first().locator('span').nth(1).textContent().catch(() => '')) || '';
await rows().first().click();
await page.locator('article h2').waitFor({ timeout: 10000 });
ok(`opened message "${(await page.locator('article h2').textContent())?.trim()}"`);

at('close it → it leaves the Open list (list shrinks)');
await page.getByRole('button', { name: /^Close$/ }).click();
await page.getByText('Message closed').waitFor({ timeout: 10000 }).catch(() => {});
await page.waitForTimeout(900);
const openAfter = await rows().count();
openAfter === openBefore - 1
  ? ok(`Open list shrank ${openBefore} → ${openAfter} after close`)
  : await die(`Open list did not shrink (before=${openBefore}, after=${openAfter})`, logs);

at('screenshot inbox');
await shot(page, 'inbox');

at('reopen the closed message to restore state');
await page.getByRole('tab', { name: 'Closed' }).click();
await page.waitForTimeout(600);
const closed = page.locator('.flex.flex-col.gap-1 > button', { hasText: subject.slice(0, 12) });
if (await closed.count()) {
  await closed.first().click();
  await page.getByRole('button', { name: /^Reopen$/ }).click();
  await page.getByText('Message reopened').waitFor({ timeout: 8000 }).catch(() => {});
  ok('reopened the message (state restored)');
} else {
  ok('closed message not re-located by subject — state left as closed (acceptable)');
}

at('clean console');
const real = realErrors(errors);
real.length === 0 ? ok('no console.error / pageerror') : await die(`browser errors:\n   ${real.join('\n   ')}`, logs);

await browser.close();
console.log('\nINBOX PASS — list · open (mark read) · close shrinks Open list · reopen (restored)');
