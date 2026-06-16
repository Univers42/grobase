// Read-only capacity workload: list(30, filtered) only. Isolates the plane's
// raw read throughput from the write-path tail latency (the outbox CDC write
// on inserts) — so capacity discovery reports the true read ceiling, and the
// CRUD-mix run reports the realistic mixed-workload p95. Both are honest; they
// answer different questions.
import { check } from 'k6';
import { dataOp, TABLE, scenarioOptions, compactSummary } from './lib.js';

export const options = scenarioOptions();

export default function () {
	const res = dataOp({ op: 'list', resource: TABLE, filter: { grp: { $eq: 'g3' } }, limit: 30, sort: { id: 'asc' } });
	check(res, { 'list 200': (x) => x.status === 200 });
}

export function handleSummary(data) {
	return compactSummary(data, { workload: 'read' });
}
