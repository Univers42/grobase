// The full quality gate, in order:
//   0. unit tests (galaxy layouts)
//   1. astro build (production)
//   2. astro preview on :4325
//   3. html-validate over dist/
//   4. csp-check (headless Chromium, real securitypolicyviolation events)
//   5. pa11y (WCAG2AA) on /, /pricing/
//   6. lighthouse ≥ LH_MIN (default 90) × 4 categories × 3 pages
// Any failure → exit non-zero (make grobase-audit is CI-gateable).
import { spawn, spawnSync } from 'node:child_process';

const BASE = 'http://127.0.0.1:4325';
const PAGES = ['/', '/pricing/', '/security/'];
const results = [];

function run(name, command, args, opts = {}) {
	console.log(`\n━━━ ${name} ━━━`);
	const result = spawnSync(command, args, { stdio: 'inherit', ...opts });
	const ok = result.status === 0;
	results.push([name, ok]);
	return ok;
}

async function waitForServer(url, timeoutMs = 60_000) {
	const start = Date.now();
	while (Date.now() - start < timeoutMs) {
		try {
			const res = await fetch(url);
			if (res.ok) return;
		} catch {}
		await new Promise((r) => setTimeout(r, 500));
	}
	throw new Error(`preview server did not come up at ${url}`);
}

run('unit tests (galaxy layouts + camera)', 'node', ['--experimental-strip-types', '--test', 'src/scripts/galaxy/layouts.test.ts', 'src/scripts/galaxy/camera.test.ts']);

// NODE_ENV=production explicitly: a development NODE_ENV (e.g. the dev
// container) would make astro build skip the hashed security.csp meta.
const buildOk = run('astro build', 'astro', ['build'], { env: { ...process.env, NODE_ENV: 'production' } });
if (!buildOk) {
	console.error('\nBuild failed — skipping the remaining gates.');
	process.exit(1);
}

// icon-safety: a static scan proving no registry icon or inline <svg> can
// inject script (allow-list of geometry tags + forbidden-pattern sweep). No
// server needed — runs against the source tree.
run('icon-safety', 'node', ['scripts/audit/icon-safety.mjs']);

run('html-validate', 'html-validate', ['dist/**/*.html']);

console.log('\n━━━ starting preview server ━━━');
const preview = spawn('astro', ['preview', '--host', '0.0.0.0', '--port', '4325'], { stdio: 'ignore' });
try {
	await waitForServer(BASE);

	run('csp-check', 'node', ['scripts/audit/csp-check.mjs', BASE]);
	for (const page of PAGES) {
		run(`pa11y ${page}`, 'pa11y', ['--config', 'scripts/audit/pa11y.config.json', `${BASE}${page}`]);
	}
	run('lighthouse', 'node', ['scripts/audit/lighthouse.mjs', BASE, `--min=${process.env.LH_MIN ?? 90}`]);
} finally {
	preview.kill('SIGTERM');
}

console.log('\n━━━ quality gate summary ━━━');
let failed = false;
for (const [name, ok] of results) {
	console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}`);
	failed ||= !ok;
}
process.exit(failed ? 1 : 0);
