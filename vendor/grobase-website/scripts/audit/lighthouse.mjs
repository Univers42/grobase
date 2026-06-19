// Reproducible Lighthouse gate over the production preview (dev-mode scores
// are meaningless). Uses the lighthouse pinned in devDependencies (PATH gets
// node_modules/.bin from container-only.mjs).
//
//   node scripts/audit/lighthouse.mjs [base-url] [--min=90]
//
// Fails (exit 1) if ANY of the 4 categories scores below --min on ANY page.
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const CATEGORIES = ['performance', 'accessibility', 'best-practices', 'seo'];
const PAGES = ['/', '/pricing/', '/security/'];
const REPORT_DIR = resolve(process.cwd(), 'test-results/lighthouse');

const argv = process.argv.slice(2);
const base = (argv.find((a) => /^https?:\/\//.test(a)) ?? process.env.LH_BASE ?? 'http://127.0.0.1:4325').replace(/\/$/, '');
const min = Number(argv.find((a) => a.startsWith('--min='))?.slice(6) ?? process.env.LH_MIN ?? 90);
const chrome = process.env.CHROME_PATH ?? '/usr/bin/chromium-browser';

function runOne(path) {
	const slug = path === '/' ? 'home' : path.replaceAll('/', '');
	const jsonPath = resolve(REPORT_DIR, `${slug}.json`);
	const result = spawnSync(
		'lighthouse',
		[
			`${base}${path}`,
			'--quiet',
			`--only-categories=${CATEGORIES.join(',')}`,
			'--chrome-flags=--headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage',
			'--output=json',
			`--output-path=${jsonPath}`,
		],
		{ stdio: ['ignore', 'ignore', 'inherit'], env: { ...process.env, CHROME_PATH: chrome } },
	);
	if (result.status !== 0) throw new Error(`lighthouse exited with code ${result.status} for ${path}`);

	const report = JSON.parse(readFileSync(jsonPath, 'utf8'));
	let pageOk = true;
	console.log(`\nLighthouse — ${base}${path}`);
	for (const key of CATEGORIES) {
		const score = Math.round((report.categories[key]?.score ?? 0) * 100);
		const ok = score >= min;
		pageOk &&= ok;
		console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${key.padEnd(16)} ${score}`);
	}
	return pageOk;
}

mkdirSync(REPORT_DIR, { recursive: true });
let allOk = true;
for (const page of PAGES) {
	allOk = runOne(page) && allOk;
}
console.log(`\nLighthouse gate (min ${min} × ${CATEGORIES.length} categories × ${PAGES.length} pages): ${allOk ? 'PASS' : 'FAIL'}`);
process.exit(allOk ? 0 : 1);
