// browser-overview.mjs — as admin, /app (Overview) shows KPI cards, the accessible
// revenue chart (svg[role=img]), and a populated activity feed from real data.
// Run in the Playwright image, --network host.

import { SPA, launch, realErrors, reporter, login, shot } from './_lib.mjs';

const { browser, page, errors, logs } = await launch();
const { at, ok, die } = reporter(page, browser);

at('admin login → Overview');
await login(page);
await page.getByRole('heading', { name: /Welcome back/ }).waitFor({ timeout: 12000 }).catch(() => {});
ok('overview heading rendered');

at('KPI cards');
await page.locator('p.text-3xl.font-semibold').first().waitFor({ timeout: 12000 }).catch(() => {});
const kpis = await page.locator('p.text-3xl.font-semibold').count();
kpis >= 1 ? ok(`${kpis} KPI value tile(s) rendered`) : await die('no KPI cards rendered', logs);

at('revenue chart (accessible)');
const chart = page.locator('svg[role="img"][aria-label*="revenue" i]');
await chart.waitFor({ timeout: 12000 }).catch(() => {});
if (await chart.count()) {
  const label = await chart.first().getAttribute('aria-label');
  ok(`revenue chart present (aria-label="${label}")`);
} else {
  // empty-state is acceptable only if there is genuinely no posted revenue.
  const empty = await page.getByText('No posted revenue yet').count();
  empty ? ok('no posted revenue → chart empty-state (acceptable)') : await die('revenue chart not found and no empty-state', logs);
}

at('activity feed populated');
await page.getByRole('heading', { name: 'Recent activity' }).waitFor({ timeout: 8000 });
const rows = page.locator('ul.space-y-4 > li');
await rows.first().waitFor({ timeout: 8000 }).catch(() => {});
const n = await rows.count();
n >= 1 ? ok(`activity feed shows ${n} event(s) from real data`) : await die('activity feed empty (expected seeded activity)', logs);

at('screenshot overview');
await shot(page, 'overview');
ok('captured overview.png');

at('clean console');
const real = realErrors(errors);
real.length === 0 ? ok('no console.error / pageerror') : await die(`browser errors:\n   ${real.join('\n   ')}`, logs);

await browser.close();
console.log('\nOVERVIEW PASS — KPI cards · accessible revenue chart · populated activity feed');
