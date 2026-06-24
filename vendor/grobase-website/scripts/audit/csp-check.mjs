// CSP proof in a real browser: loads each page in headless Chromium (the
// puppeteer that ships with pa11y; PUPPETEER_EXECUTABLE_PATH points at the
// apk chromium — nothing is downloaded), scrolls to the bottom to exercise
// the galaxy + scroll code, and fails on:
//   - any securitypolicyviolation event
//   - any console error
//   - a meta CSP that is missing, lacks hashes, or contains 'unsafe-inline'
//
//   node scripts/audit/csp-check.mjs [base-url]
import puppeteer from 'puppeteer';

const PAGES = ['/', '/pricing/', '/security/'];
const base = (process.argv[2] ?? 'http://127.0.0.1:4325').replace(/\/$/, '');

const browser = await puppeteer.launch({
	executablePath: process.env.PUPPETEER_EXECUTABLE_PATH || process.env.CHROME_PATH || undefined,
	args: ['--no-sandbox', '--disable-dev-shm-usage'],
});

let failed = false;

for (const path of PAGES) {
	const page = await browser.newPage();
	const consoleErrors = [];
	page.on('console', (msg) => {
		if (msg.type() === 'error') consoleErrors.push(msg.text());
	});
	await page.evaluateOnNewDocument(() => {
		window.__cspViolations = [];
		document.addEventListener('securitypolicyviolation', (e) => {
			window.__cspViolations.push(`${e.violatedDirective}: ${e.blockedURI || e.sourceFile || 'inline'}`);
		});
	});

	await page.goto(`${base}${path}`, { waitUntil: 'networkidle0', timeout: 60_000 });
	// Exercise scroll-driven code (galaxy morphs, IntersectionObserver states).
	await page.evaluate(async () => {
		const total = document.body.scrollHeight;
		for (let y = 0; y <= total; y += Math.max(300, total / 12)) {
			window.scrollTo(0, y);
			await new Promise((r) => setTimeout(r, 120));
		}
		window.scrollTo(0, 0);
	});
	await new Promise((r) => setTimeout(r, 400));

	const violations = await page.evaluate(() => window.__cspViolations ?? []);
	const meta = await page.evaluate(
		() => document.querySelector('meta[http-equiv="Content-Security-Policy"]')?.getAttribute('content') ?? '',
	);

	const problems = [];
	if (violations.length > 0) problems.push(`CSP violations: ${violations.join(' | ')}`);
	if (consoleErrors.length > 0) problems.push(`console errors: ${consoleErrors.join(' | ')}`);
	if (!meta) problems.push('no <meta http-equiv="Content-Security-Policy"> found');
	else {
		if (meta.includes("'unsafe-inline'")) problems.push("meta CSP contains 'unsafe-inline'");
		if (!meta.includes('sha256-') && /<style|<script/.test(await page.content())) {
			// Astro hashes every inline style/script it emits; absence means the
			// strict-CSP build path regressed.
			problems.push('meta CSP has no sha256- hashes');
		}
	}

	console.log(`csp-check ${path}: ${problems.length === 0 ? 'PASS' : `FAIL\n  - ${problems.join('\n  - ')}`}`);
	failed ||= problems.length > 0;
	await page.close();
}

await browser.close();
process.exit(failed ? 1 : 0);
