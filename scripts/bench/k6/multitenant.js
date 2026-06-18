// Multi-tenant fan-out (program B2): replay the seeded tenant fleet, each VU
// iteration picking a tenant (uniform or zipf-skewed) and hitting /data/v1 with
// ITS key + mount. Exercises the verify-cache, mount-cache and pool registry
// under realistic N-tenant pressure — the signals B3's /metrics expose.
//
// Env: BASE, ANON, TENANTS_FILE (JSON array of {key, db_id}), RATE, DURATION,
//      DIST (uniform|zipf).
import http from 'k6/http';
import { check } from 'k6';
import { SharedArray } from 'k6/data';
import { Counter } from 'k6/metrics';
import { scenarioOptions, compactSummary } from './lib.js';

export const options = scenarioOptions();

const serverErrors = new Counter('bench_server_errors');
const rateLimited = new Counter('bench_rate_limited');

const tenants = new SharedArray('tenants', () => JSON.parse(open(__ENV.TENANTS_FILE)));
const DIST = __ENV.DIST || 'uniform';
const TABLE = __ENV.TABLE || 'bench_items';
// Unique per k6 process — bare mt-VU-ITER ids 409 against rows a previous
// run/warmup left behind (same fix as crud.js).
const NONCE = (__ENV.RUN_NONCE || Date.now().toString(36)).toString();

// Zipf-ish skew: a few tenants take most traffic (the realistic hot-tenant
// shape that stresses one pool while others idle out of the LRU).
function pickIndex() {
	if (DIST === 'zipf') {
		const u = Math.random();
		return Math.min(tenants.length - 1, Math.floor(tenants.length * u * u));
	}
	return Math.floor(Math.random() * tenants.length);
}

export default function () {
	const t = tenants[pickIndex()];
	const headers = { 'Content-Type': 'application/json', apikey: __ENV.ANON, 'X-Baas-Api-Key': t.key };
	// 90% reads (the realistic multi-tenant mix); 10% inserts to keep pools warm.
	const op = Math.random() < 0.9
		? { op: 'list', resource: TABLE, limit: 10 }
		: { op: 'insert', resource: TABLE, data: { id: `mt-${NONCE}-${__VU}-${__ITER}`, name: 'mt', grp: 'g1', val: __ITER % 100 } };
	const res = http.post(`${__ENV.BASE}/data/v1/query`, JSON.stringify({ db_id: t.db_id, operation: op }), { headers });
	if (res.status === 429) rateLimited.add(1);
	else if (res.status >= 500) serverErrors.add(1);
	check(res, { 'mt 2xx/4xx not 5xx': (x) => x.status < 500 });
}

export function handleSummary(data) {
	return compactSummary(data, { workload: 'multitenant', tenants: tenants.length, dist: DIST });
}
