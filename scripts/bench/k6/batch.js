// Batch scenario: 10-item batches (atomic on pg/mysql) through the gateway.
import { check } from 'k6';
import { dataOp, TABLE, scenarioOptions, compactSummary } from './lib.js';

export const options = scenarioOptions();

export default function () {
	// /data/v1 batch contract: sub-operations ride in `data`, each with its
	// own `resource` (data-plane-core operation.rs batch_items).
	const items = [];
	for (let i = 0; i < 10; i += 1) {
		items.push({ op: 'insert', resource: TABLE, data: { id: `bb-${NONCE}-${__VU}-${__ITER}-${i}`, name: 'batch', grp: `g${i % 8}`, val: i } });
	}
	const res = dataOp({ op: 'batch', resource: TABLE, data: items });
	check(res, { 'batch 2xx': (x) => x.status === 200 || x.status === 201 });
}

export function handleSummary(data) {
	return compactSummary(data, { workload: 'batch', items_per_batch: 10 });
}
