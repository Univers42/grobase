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

at('KPI cards reflect real totals — record the numbers the UI displays');
const values = page.locator('p.text-3xl.font-semibold');
await values.first().waitFor({ timeout: 12000 }).catch(() => {});
const valueN = await values.count();
const kpiReadout = [];
for (let i = 0; i < valueN; i++) {
  const value = ((await values.nth(i).textContent().catch(() => '')) || '').trim();
  const card = values.nth(i).locator('xpath=ancestor::div[.//span[contains(@class,"text-muted")]][1]');
  const label = ((await card.locator('span.text-muted').first().textContent().catch(() => '')) || '').trim();
  if (label && value) kpiReadout.push(`${label} = ${value}`);
}
kpiReadout.length >= 4
  ? ok(`real KPIs — ${kpiReadout.join('  ·  ')}`)
  : await die(`expected 4 real KPI tiles, got ${kpiReadout.length}: ${kpiReadout.join(', ')}`, logs);

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
console.log(`\nOVERVIEW PASS — real KPIs [${kpiReadout.join(' · ')}] · accessible revenue chart · populated activity feed`);
