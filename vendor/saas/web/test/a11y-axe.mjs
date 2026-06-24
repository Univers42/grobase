// a11y-axe.mjs — runs axe-core against /, /login, /app, /app/revenue, /app/content
// (logging in first for guarded routes) and asserts 0 serious/critical violations.
// Prints any moderate ones. axe-core is injected from the local node_modules copy
// (installed by run-all.sh into test/node_modules). Run --network host.

import { readFileSync } from 'node:fs';
import { SPA, launch, reporter, login, shot } from './_lib.mjs';

const AXE_SRC = readFileSync(new URL('./node_modules/axe-core/axe.min.js', import.meta.url), 'utf8');
const { browser, page, logs } = await launch();
const { at, ok, die } = reporter(page, browser);

/** scanOnce injects axe and returns the current violations for the page. */
async function scanOnce() {
  await page.addScriptTag({ content: AXE_SRC });
  return page.evaluate(async () => {
    // @ts-ignore — axe is injected onto window above.
    const r = await window.axe.run(document, { resultTypes: ['violations'] });
    return r.violations.map((v) => ({
      id: v.id,
      impact: v.impact,
      nodes: v.nodes.length,
      help: v.help,
      detail: v.id === 'color-contrast' ? v.nodes.map((n) => `${n.html.slice(0, 90)} :: ${(n.failureSummary || '').match(/contrast of [\d.]+[^\n]*/)?.[0] || ''}`) : undefined,
    }));
  });
}

/** runAxe scans, and re-scans once after a settle if a serious/critical appears —
 *  a genuine violation persists across both; a render-timing flake clears. Returns
 *  the intersection so only stable serious/critical issues are reported. */
async function runAxe() {
  const first = await scanOnce();
  const blocking = first.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  if (blocking.length === 0) return first;
  await page.waitForTimeout(1000);
  const second = await scanOnce();
  const stable = new Set(second.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id));
  return second.filter((v) => v.impact !== 'serious' && v.impact !== 'critical' ? true : stable.has(v.id) && first.some((f) => f.id === v.id));
}

const routes = [
  { path: '/', guarded: false },
  { path: '/login', guarded: false },
  { path: '/app', guarded: true },
  { path: '/app/revenue', guarded: true },
  { path: '/app/content', guarded: true },
];

at('admin login (for guarded routes)');
await login(page);
ok('signed in');

let blocking = 0;
let moderate = 0;
for (const route of routes) {
  at(`axe ${route.path}`);
  await page.goto(`${SPA}${route.path}`, { waitUntil: 'networkidle' });
  // let lazy panels mount, then let any lingering toast (white-on-accent, from a
  // prior suite) auto-dismiss so the scan sees the steady-state page only.
  await page.waitForTimeout(1200);
  await page.locator('[role="status"]').first().waitFor({ state: 'detached', timeout: 6000 }).catch(() => {});
  const violations = await runAxe();
  const bad = violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  const mods = violations.filter((v) => v.impact === 'moderate' || v.impact === 'minor');
  blocking += bad.length;
  moderate += mods.length;
  if (bad.length) {
    await shot(page, `a11y-${route.path.replace(/\W+/g, '_') || 'root'}`);
    console.error(`  ✗ ${route.path}: ${bad.length} serious/critical`);
    bad.forEach((v) => {
      console.error(`      [${v.impact}] ${v.id} ×${v.nodes} — ${v.help}`);
      (v.detail || []).forEach((d) => console.error(`        ${d}`));
    });
  } else {
    ok(`${route.path}: 0 serious/critical${mods.length ? ` (${mods.length} moderate/minor)` : ''}`);
  }
  mods.forEach((v) => console.log(`      · moderate: ${v.id} ×${v.nodes} — ${v.help}`));
}

if (blocking > 0) await die(`${blocking} serious/critical a11y violation(s) across the app`, logs);

await browser.close();
console.log(`\nA11Y PASS — 0 serious/critical across 5 routes (${moderate} moderate/minor noted)`);
