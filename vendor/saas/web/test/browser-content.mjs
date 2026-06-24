// browser-content.mjs — /app/content edits a settings field, saves, reloads, and
// asserts the value persists (Mongo upsert). Restores the original tagline so the
// suite is idempotent. Run in the Playwright image, --network host.

import { SPA, launch, realErrors, reporter, login, shot } from './_lib.mjs';

const { browser, page, errors, logs } = await launch();
const { at, ok, die } = reporter(page, browser);

/** taglineInput is the "Tagline" field, located via its associated label. */
function taglineInput() {
  return page.getByLabel('Tagline');
}

/** waitToast polls for a toast whose text contains `needle` (toasts auto-dismiss). */
async function waitToast(needle, ms = 12000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const texts = await page.locator('[role="status"]').allTextContents();
    if (texts.some((t) => t.includes(needle))) return true;
    await page.waitForTimeout(150);
  }
  return false;
}

at('admin login → Content');
await login(page);
await page.goto(`${SPA}/app/content`, { waitUntil: 'domcontentloaded' });
await page.getByRole('heading', { name: 'Content & settings' }).waitFor({ timeout: 12000 });

at('settings form loaded with a Tagline field');
await taglineInput().waitFor({ timeout: 12000 });
const original = await taglineInput().inputValue();
ok(`tagline before = "${original}"`);

at('edit + save the tagline');
const next = `Observed @ ${Date.now().toString(36)}`;
await taglineInput().fill(next);
await page.getByRole('button', { name: 'Save changes' }).click();
(await waitToast('Settings saved'))
  ? ok('toast: "Settings saved"')
  : await die('no save-success toast', logs);

at('reload → the new value persists (Mongo upsert)');
await page.reload({ waitUntil: 'domcontentloaded' });
await taglineInput().waitFor({ timeout: 12000 });
const after = await taglineInput().inputValue();
after === next ? ok(`reload confirms tagline = "${after}" (persisted)`) : await die(`tagline did not persist: want "${next}", got "${after}"`, logs);
await shot(page, 'content');

at('restore the original tagline');
await taglineInput().fill(original);
await page.getByRole('button', { name: 'Save changes' }).click();
await waitToast('Settings saved');
ok(`restored tagline → "${original}"`);

at('clean console');
const real = realErrors(errors);
real.length === 0 ? ok('no console.error / pageerror') : await die(`browser errors:\n   ${real.join('\n   ')}`, logs);

await browser.close();
console.log('\nCONTENT PASS — edit settings field · save · reload persists (Mongo upsert) · restored');
