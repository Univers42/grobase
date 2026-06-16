// The canonical CRUD mix (METHOD.md): 70% list(30, filtered) / 20% insert /
// 5% update-by-pk / 5% delete-by-pk against bench_items through the gateway.
import { check } from 'k6';
import { Trend } from 'k6/metrics';
import { dataOp, TABLE, scenarioOptions, compactSummary } from './lib.js';

export const options = scenarioOptions();

const opList = new Trend('bench_op_list');
const opInsert = new Trend('bench_op_insert');
const opUpdate = new Trend('bench_op_update');
const opDelete = new Trend('bench_op_delete');

// Per-VU id memory so update/delete target rows this VU actually inserted;
// fallback to the seeded s0..s499 set (updates only — deletes of seeded rows
// would erode the list-filter working set).
let lastInserted = null;

// Per-process nonce: warmup + each of the 3 measured runs replay the SAME
// (__VU, __ITER) sequence into ONE shared table, so a bare b-VU-ITER id 409s
// against the previous process's rows (err climbed 2.6→5.5→8.1% run-over-run
// from pure id collisions, zero 5xx). The nonce makes ids unique per process.
const NONCE = (__ENV.RUN_NONCE || Date.now().toString(36)).toString();

export default function () {
	const r = Math.random();
	if (r < 0.7) {
		const res = dataOp({ op: 'list', resource: TABLE, filter: { grp: { $eq: 'g3' } }, limit: 30, sort: { id: 'asc' } }, opList);
		check(res, { 'list 200': (x) => x.status === 200 });
	} else if (r < 0.9) {
		const id = `b-${NONCE}-${__VU}-${__ITER}`;
		const res = dataOp({ op: 'insert', resource: TABLE, data: { id, name: `bench-${__ITER}`, grp: `g${__ITER % 8}`, val: __ITER % 1000 } }, opInsert);
		if (res.status === 200 || res.status === 201) lastInserted = id;
		check(res, { 'insert 2xx': (x) => x.status === 200 || x.status === 201 });
	} else if (r < 0.95) {
		const id = lastInserted || `s${Math.floor(Math.random() * 500)}`;
		const res = dataOp({ op: 'update', resource: TABLE, filter: { id: { $eq: id } }, data: { val: __ITER % 1000 } }, opUpdate);
		check(res, { 'update 2xx': (x) => x.status >= 200 && x.status < 300 });
	} else if (lastInserted) {
		// Delete only VU-owned rows that exist — deleting a phantom id would
		// 404 and pollute the error rate with workload artifacts.
		const id = lastInserted;
		lastInserted = null;
		const res = dataOp({ op: 'delete', resource: TABLE, filter: { id: { $eq: id } } }, opDelete);
		check(res, { 'delete 2xx': (x) => x.status >= 200 && x.status < 300 });
	} else {
		// No VU-owned row yet → insert instead (keeps the op count constant;
		// the realized delete share converges to its 5% as VUs warm up).
		const id = `b-${NONCE}-${__VU}-${__ITER}`;
		const res = dataOp({ op: 'insert', resource: TABLE, data: { id, name: `bench-${__ITER}`, grp: `g${__ITER % 8}`, val: __ITER % 1000 } }, opInsert);
		if (res.status === 200 || res.status === 201) lastInserted = id;
		check(res, { 'insert 2xx': (x) => x.status === 200 || x.status === 201 });
	}
}

export function handleSummary(data) {
	const t = (m) => {
		const v = (data.metrics[m] || {}).values || {};
		return { med: v.med ?? null, p95: v['p(95)'] ?? null, p99: v['p(99)'] ?? null, count: v.count ?? 0 };
	};
	return compactSummary(data, {
		workload: 'crud',
		ops: { list: t('bench_op_list'), insert: t('bench_op_insert'), update: t('bench_op_update'), delete: t('bench_op_delete') },
	});
}
