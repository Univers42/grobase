// Aggregate scenario: count+sum and a group-by — the beyond-CRUD read path.
import { check } from 'k6';
import { dataOp, TABLE, scenarioOptions, compactSummary } from './lib.js';

export const options = scenarioOptions();

export default function () {
	const groupBy = Math.random() < 0.5;
	const operation = groupBy
		? { op: 'aggregate', resource: TABLE, aggregate: { groupBy: ['grp'], aggregates: [{ func: 'count', alias: 'c' }] }, sort: { grp: 'asc' }, limit: 10 }
		: { op: 'aggregate', resource: TABLE, aggregate: { aggregates: [{ func: 'count', alias: 'total' }, { func: 'sum', field: 'val', alias: 'sum_val' }] } };
	const res = dataOp(operation);
	check(res, { 'aggregate 200': (x) => x.status === 200 });
}

export function handleSummary(data) {
	return compactSummary(data, { workload: 'aggregate' });
}
