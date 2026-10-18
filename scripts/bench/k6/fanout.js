// Workspace-open fan-out replay: reproduce the osionos bridge's open against
// PostgREST through the edge, in the bridge's two shapes — n1 (per-page
// membership check + per-page content fetch, sequentially) and batched
// (membership once, slim page index, first page content only).
// Env contract (passed via -e):
//   BASE   origin, e.g. https://127.0.0.1:8443
//   ANON   apikey header value
//   JWT    Authorization: Bearer value
//   WS     workspace uuid
//   MODE   'n1', 'batched' or 'embed' (USER = a member of WS)
//   BURST  concurrent VUs (default 50)
//   ITER   iterations (opens) per VU (default 3)
//   K6_OUT_FILE  compact summary destination
// Ponytail: wire_bytes (Content-Length) reads 0 on chunked/gzip responses; wire_bytes_per_open
// (k6 data_received ÷ opens, headers included) is the trustworthy wire figure.
// Ponytail: the n1 replay approximates the bridge from Kong-comment evidence (kong.yml:223), not from bridge source.
import http from 'k6/http';
import { Counter, Trend } from 'k6/metrics';

export const openMs = new Trend('open_ms');
export const openBytes = new Trend('open_bytes');
export const wireBytes = new Trend('wire_bytes');
export const roundTrips = new Counter('round_trips');
export const rateLimited = new Counter('bench_rate_limited');
export const serverErrors = new Counter('bench_server_errors');

const BASE = __ENV.BASE;
const WS = __ENV.WS;
const MODE = __ENV.MODE || 'n1';
// The bridge's shape since ADR 0005: one statement anchored on the caller's members row.
// Ponytail: the column list is a guess at the bridge's sidebar projection (USER = the member).
const EMBED_URL = `${BASE}/rest/v1/osionos_workspace_members?user_id=eq.${__ENV.USER}&workspace_id=eq.${WS}&select=role,workspace:osionos_workspaces!workspace_id(id,pages:osionos_pages!workspace_id(id,parent_page_id,title,icon,cover,surface,visibility,sort_order,updated_at,archived_at,is_template,database_id))&limit=2`;
const MEMBERS_URL = `${BASE}/rest/v1/osionos_workspace_members?workspace_id=eq.${WS}&select=user_id&limit=1`;

const HEADERS = {
	apikey: __ENV.ANON,
	Authorization: `Bearer ${__ENV.JWT}`,
	'Accept-Encoding': 'gzip',
};

export const options = {
	insecureSkipTLSVerify: true,
	summaryTrendStats: ['med', 'p(95)', 'p(99)', 'max', 'count'],
	scenarios: {
		open: {
			executor: 'per-vu-iterations',
			vus: Number(__ENV.BURST || 50),
			iterations: Number(__ENV.ITER || 3),
			exec: 'openWorkspace',
		},
	},
};

function get(acc, url) {
	const res = http.get(url, { headers: HEADERS });
	roundTrips.add(1);
	if (res.status === 429) rateLimited.add(1);
	else if (res.status >= 500) serverErrors.add(1);
	acc.body += String(res.body || '').length;
	acc.wire += Number(res.headers['Content-Length'] || 0);
	return res;
}

function parse(res) {
	try {
		return res.json();
	} catch (e) {
		return [];
	}
}

// One simulated workspace open; all requests sequential, as the bridge does.
export function openWorkspace() {
	const start = Date.now();
	const acc = { body: 0, wire: 0 };
	if (MODE === 'n1') {
		const listed = get(acc, `${BASE}/rest/v1/osionos_pages?workspace_id=eq.${WS}&select=*`);
		for (const page of parse(listed)) {
			get(acc, MEMBERS_URL);
			get(acc, `${BASE}/rest/v1/osionos_pages?id=eq.${page.id}&select=*`);
		}
	} else if (MODE === 'embed') {
		get(acc, EMBED_URL);
	} else {
		get(acc, MEMBERS_URL);
		const indexed = get(acc, `${BASE}/rest/v1/osionos_pages?workspace_id=eq.${WS}&select=id,parent_page_id,title,icon,sort_order,updated_at`);
		const first = parse(indexed)[0];
		if (first) get(acc, `${BASE}/rest/v1/osionos_pages?id=eq.${first.id}&select=content`);
	}
	openMs.add(Date.now() - start);
	openBytes.add(acc.body);
	wireBytes.add(acc.wire);
}

export function handleSummary(data) {
	const vals = (name) => data.metrics[name]?.values || {};
	const t = (name) => {
		const v = vals(name);
		return { med: v.med ?? null, p95: v['p(95)'] ?? null, p99: v['p(99)'] ?? null, max: v.max ?? null, count: v.count ?? 0 };
	};
	const opens = vals('open_ms').count || 0;
	const trips = vals('round_trips').count || 0;
	const http = t('http_req_duration');
	const out = {
		mode: MODE,
		burst: Number(__ENV.BURST || 50),
		iter: Number(__ENV.ITER || 3),
		open_ms: t('open_ms'),
		round_trips_per_open: opens ? Math.round((trips / opens) * 100) / 100 : null,
		open_bytes_med: vals('open_bytes').med ?? null,
		wire_bytes_med: vals('wire_bytes').med ?? null,
		wire_bytes_per_open: opens ? Math.round((vals('data_received').count || 0) / opens) : null,
		http: { med: http.med, p95: http.p95, p99: http.p99 },
		err_pct: Math.round((vals('http_req_failed').rate || 0) * 10000) / 100,
		rate_limited: vals('bench_rate_limited').count || 0,
		server_errors: vals('bench_server_errors').count || 0,
	};
	const file = __ENV.K6_OUT_FILE || '/out/k6-run.json';
	return { [file]: JSON.stringify(out, null, 1), stdout: `\n  mode=${out.mode} rt/open=${out.round_trips_per_open} open_ms p95=${out.open_ms.p95}ms wire/open=${out.wire_bytes_per_open}B err=${out.err_pct}% 429s=${out.rate_limited}\n` };
}
