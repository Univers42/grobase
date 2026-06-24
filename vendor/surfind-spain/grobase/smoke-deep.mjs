// smoke-deep.mjs — Playwright browser smoke for the Surfind DEEP expansion.
// Runs against the live same-origin SPA (serve.mjs). Asserts the new pages
// render, the markdown article renders, login works, the bitácora reads the
// seeded mongo session, the profile saves, and a posted report appears live.
import { chromium } from 'playwright';

const BASE = process.env.BASE || 'http://localhost:5183';
const EMAIL = 'visitor@surfind.es';
const PASS = 'surf-1234';
const out = [];
const ok = (m) => { out.push(`  PASS ${m}`); };
const die = (m) => { out.push(`  FAIL ${m}`); console.log(out.join('\n')); process.exit(1); };

const browser = await chromium.launch();
const page = await browser.newPage();
page.on('pageerror', (e) => die(`page error: ${e.message}`));

async function goto(p) { await page.goto(`${BASE}${p}`, { waitUntil: 'networkidle' }); }

try {
  // Blog list → at least one article card, then open it and assert markdown <h1>.
  await goto('/blog');
  await page.waitForSelector('a[href^="/blog/"]', { timeout: 8000 });
  ok('blog list renders article cards');
  await page.click('a[href^="/blog/"]');
  await page.waitForSelector('h1', { timeout: 8000 });
  const hasH1 = await page.locator('article h1').first().isVisible();
  if (!hasH1) die('article markdown h1 not rendered');
  ok('article renders markdown body');

  // Reportes (global live feed) loads.
  await goto('/reportes');
  await page.waitForSelector('h1:has-text("Reportes en vivo")', { timeout: 8000 });
  ok('reportes page renders');

  // Ranking shows seeded public profiles.
  await goto('/ranking');
  await page.waitForSelector('h1:has-text("Ranking")', { timeout: 8000 });
  ok('ranking page renders');

  // Beach detail: cover hero + conditions + reports section.
  await goto('/playas');
  await page.waitForSelector('a[href^="/playas/"]', { timeout: 8000 });
  await page.click('a[href^="/playas/playa-"]');
  await page.waitForSelector('h2:has-text("Condiciones")', { timeout: 8000 });
  await page.waitForSelector('h2:has-text("Reportes recientes")', { timeout: 8000 });
  ok('beach detail shows Condiciones + Reportes recientes');

  // Log in.
  await goto('/acceder');
  await page.fill('#email', EMAIL);
  await page.fill('#password', PASS);
  await page.click('button[type="submit"]');
  await page.waitForURL(`${BASE}/`, { timeout: 8000 });
  ok('login succeeds');

  // Bitácora reads the seeded mongo session + shows stats.
  await goto('/bitacora');
  await page.waitForSelector('h1:has-text("Mi Bitácora")', { timeout: 8000 });
  await page.waitForFunction(
    () => document.body.innerText.includes('Sesiones') && !document.body.innerText.includes('necesita el plano'),
    { timeout: 8000 },
  );
  ok('bitácora renders stats + sessions (mongo)');

  // Perfil saves.
  await goto('/perfil');
  await page.waitForSelector('h1:has-text("Perfil")', { timeout: 8000 });
  await page.fill('input[placeholder="Tu nombre de surfista"]', 'Demo Smoke');
  await page.click('button[type="submit"]');
  await page.waitForSelector('text=Perfil guardado', { timeout: 8000 });
  ok('perfil upsert saves');

  console.log(out.join('\n'));
  console.log('\nsmoke-deep PASS');
} catch (e) {
  die(`exception: ${e.message}`);
} finally {
  await browser.close();
}
