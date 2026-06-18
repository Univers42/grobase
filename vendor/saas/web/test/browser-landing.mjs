// browser-landing.mjs — loads the public landing page and asserts the hero
// headline + a CTA link render, with NO console.error, NO pageerror, NO CSP
// violation. Screenshots the hero. Run in the Playwright image, --network host.

import { SPA, launch, realErrors, reporter, shot } from './_lib.mjs';

const { browser, page, errors, logs } = await launch();
const { at, ok, die } = reporter(page, browser);

at('load /');
await page.goto(`${SPA}/`, { waitUntil: 'networkidle' });

at('hero headline');
const heading = page.locator('h1', { hasText: 'Your backend' });
(await heading.count()) ? ok('hero headline "Your backend, beautifully observed." present') : await die('hero headline not found', logs);
(await page.getByText('beautifully observed.').count()) ? ok('hero subline present') : await die('hero subline missing', logs);

at('primary CTAs');
const signin = page.locator('a[href="/login"]', { hasText: 'Sign in' });
const create = page.locator('a[href="/register"]', { hasText: 'Create account' });
(await signin.count()) ? ok('CTA "Sign in" → /login') : await die('Sign in CTA missing', logs);
(await create.count()) ? ok('CTA "Create account" → /register') : await die('Create account CTA missing', logs);

at('screenshot the hero');
await shot(page, 'landing-hero');
ok('captured landing-hero.png');

at('clean console (no error/pageerror/CSP)');
const real = realErrors(errors);
real.length === 0 ? ok('no console.error / pageerror / CSP violation') : await die(`browser errors:\n   ${real.join('\n   ')}`, logs);

await browser.close();
console.log('\nLANDING PASS — hero + CTAs render, clean console');
