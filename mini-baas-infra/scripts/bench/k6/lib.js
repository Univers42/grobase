// Shared k6 plumbing for the grobase bench harness (see ../METHOD.md).
// Env contract (passed by load.sh via -e):
//   BASE   gateway origin, e.g. http://127.0.0.1:8002   (Kong)
//   ANON   Kong consumer apikey
//   APPK   tenant api key (mbk_…)
//   DBID   mount id
//   TABLE  bench table name
//   RATE   target arrival rate (req/s), DURATION (e.g. "60s")
//   K6_OUT_FILE  compact summary destination (mounted /out)
import http from 'k6/http';
import { Counter } from 'k6/metrics';

export const rateLimited = new Counter('bench_rate_limited');
export const serverErrors = new Counter('bench_server_errors');

export const BASE = __ENV.BASE;
export const TABLE = __ENV.TABLE || 'bench_items';
const DBID = __ENV.DBID;

const HEADERS = {
	'Content-Type': 'application/json',
	apikey: __ENV.ANON,
	'X-Baas-Api-Key': __ENV.APPK,
};

// One product-path request: Kong → /data/v1/query → Rust plane → engine.
export function dataOp(operation, trend) {
	const body = JSON.stringify({ db_id: DBID, operation });
	const res = http.post(`${BASE}/data/v1/query`, body, { headers: HEADERS });
	if (trend) trend.add(res.timings.duration);
	if (res.status === 429) rateLimited.add(1);
	else if (res.status >= 500) serverErrors.add(1);
	return res;
}

export function scenarioOptions() {
	const rate = Number(__ENV.RATE || 50);
	return {
		summaryTrendStats: ['med', 'p(95)', 'p(99)', 'max', 'count'],
		scenarios: {
			load: {
				executor: 'constant-arrival-rate',
				rate,
				timeUnit: '1s',
				duration: __ENV.DURATION || '60s',
				preAllocatedVUs: Math.min(Math.max(Math.ceil(rate / 2), 10), 500),
				maxVUs: Math.min(Math.max(rate * 2, 50), 2000),
			},
		},
	};
}

// Compact artifact: one JSON object per run (load.sh aggregates the 3 runs +
// env block into the final artifact).
export function compactSummary(data, extra) {
	const t = (name) => {
		const v = (data.metrics[name] || {}).values || {};
		return { med: v.med ?? null, p95: v['p(95)'] ?? null, p99: v['p(99)'] ?? null, max: v.max ?? null, count: v.count ?? 0 };
	};
	const reqs = ((data.metrics.http_reqs || {}).values || {}).count || 0;
	const durMs = (data.state || {}).testRunDurationMs || 1;
	const failedRate = ((data.metrics.http_req_failed || {}).values || {}).rate || 0;
	const out = {
		rate_target: Number(__ENV.RATE || 0),
		duration_ms: Math.round(durMs),
		rps_achieved: Math.round((reqs / durMs) * 1000 * 100) / 100,
		http: t('http_req_duration'),
		err_pct: Math.round(failedRate * 10000) / 100,
		rate_limited: ((data.metrics.bench_rate_limited || {}).values || {}).count || 0,
		server_errors: ((data.metrics.bench_server_errors || {}).values || {}).count || 0,
		...extra,
	};
	const file = __ENV.K6_OUT_FILE || '/out/k6-run.json';
	return { [file]: JSON.stringify(out, null, 1), stdout: `\n  rps=${out.rps_achieved} p95=${out.http.p95}ms p99=${out.http.p99}ms err=${out.err_pct}% 429s=${out.rate_limited}\n` };
}
