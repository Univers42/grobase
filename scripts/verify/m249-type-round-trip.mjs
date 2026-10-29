// **************************************************************************** //
//                                                                              //
//                                                         :::      ::::::::    //
//    m249-type-round-trip.mjs                           :+:      :+:    :+:    //
//                                                     +:+ +:+         +:+      //
//    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         //
//                                                 +#+#+#+#+#+   +#+            //
//    Created: 2026/10/29 19:00:00 by dlesieur          #+#    #+#              //
//    Updated: 2026/10/29 19:00:00 by dlesieur         ###   ########.fr        //
//                                                                              //
// **************************************************************************** //
//
// The live half of m249: on each mount in M249_MOUNTS (engine=uuid,…) create a
// scratch table with one column per creatable normalized type, insert one value
// of each, read it back through the gateway, check value + described type, drop
// the table. The verdict per cell is PASS, GAP (a known open item, listed in
// GAPS with its reason) or FAIL. A GAP that starts passing also fails, so the
// ledger cannot outlive the gap.
//
// Caveat: it compares the API round trip, not the stored bytes — a binary value
// an engine stores as its hex text reads back identically and passes. Bigint is
// probed at 2^53-1 because reads past 2^53 still travel as JSON numbers.

const KONG = process.env.BAAS_KONG_URL ?? 'http://127.0.0.1:8000';
const KEY = process.env.BAAS_API_KEY ?? '';
const ANON = process.env.BAAS_ANON_KEY ?? '';
const MOUNTS = (process.env.M249_MOUNTS ?? '')
  .split(',')
  .filter(Boolean)
  .map((pair) => pair.split('='));

// MySQL and MSSQL return `2026-10-29 12:34:56` with no zone; the router writes UTC.
const asUtc = (text) => {
  const iso = String(text).replace(' ', 'T');
  return /(Z|[+-]\d\d:?\d\d)$/.test(iso) ? iso : `${iso}Z`;
};
const sameInstant = (a, b) => Date.parse(a) === Date.parse(asUtc(b));
const parsedJson = (v) => (typeof v === 'string' ? JSON.parse(v) : v);

// [column, normalized type, written value, read-back check]
const CASES = [
  ['c_text', 'text', 'héllo ✓', (v) => v === 'héllo ✓'],
  ['c_int', 'integer', 42, (v) => Number(v) === 42],
  ['c_big', 'bigint', '9007199254740991', (v) => String(v) === '9007199254740991'],
  ['c_float', 'float', 1.5, (v) => Number(v) === 1.5],
  ['c_dec', 'decimal', '12.50', (v) => Number(v) === 12.5],
  ['c_bool', 'boolean', true, (v) => v === true || v === 1],
  ['c_date', 'date', '2026-10-29', (v) => String(v).startsWith('2026-10-29')],
  ['c_ts', 'datetime', '2026-10-29T12:34:56Z', (v) => sameInstant('2026-10-29T12:34:56Z', v)],
  ['c_json', 'json', { k: [1, 'a'] }, (v) => JSON.stringify(parsedJson(v)) === '{"k":[1,"a"]}'],
  ['c_uuid', 'uuid', '6f1c2d3e-4a5b-4c6d-8e7f-001122334455', (v) => String(v).toLowerCase() === '6f1c2d3e-4a5b-4c6d-8e7f-001122334455'],
  ['c_bin', 'binary', '\\xdead00ff', (v) => String(v).toLowerCase() === '\\xdead00ff'],
  ['c_time', 'time', '12:30:00', (v) => String(v).includes('12:30:00')],
];

// engine → column → reason. Each entry is an open item in the plan (G7 "Open").
const GAPS = {};

async function call(path, body) {
  const headers = { 'Content-Type': 'application/json', 'X-Baas-Api-Key': KEY };
  if (ANON) headers.apikey = ANON;
  const res = await fetch(`${KONG}${path}`, { method: 'POST', headers, body: JSON.stringify(body) });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = text;
  }
  return { status: res.status, json };
}

const brief = (json) => JSON.stringify(json?.message ?? json).slice(0, 160);
const ddl = (id, body) => call(`/query/v1/${id}/schema/ddl`, body);
const rowsOf = (json) => (Array.isArray(json) ? json : (json?.rows ?? json?.data ?? json?.records ?? []));

async function describeTypes(id, table) {
  const headers = { 'X-Baas-Api-Key': KEY, ...(ANON ? { apikey: ANON } : {}) };
  const res = await fetch(`${KONG}/query/v1/${id}/schema`, { headers });
  const tables = (await res.json())?.tables ?? [];
  const found = tables.find((t) => t.name === table);
  return Object.fromEntries((found?.columns ?? []).map((c) => [c.name, c.normalized_type]));
}

// One column per type, added and filled alone, so one refused type cannot hide
// the others.
async function probeEngine(engine, id) {
  const table = `m249_${process.pid}_${engine.slice(0, 5)}`;
  const column = (name, type) => ({ name, normalized_type: type, nullable: true, default: null, enum_values: null });
  const idColumn = { ...column('id', 'integer'), nullable: false };
  const created = await ddl(id, { op: 'create_table', table, columns: [idColumn], primary_key: ['id'] });
  if (created.status >= 300) return [['(table)', 'FAIL', `create_table ${created.status}: ${brief(created.json)}`]];
  try {
    const cells = [];
    for (const [name, type, value, check] of CASES) {
      const added = await ddl(id, { op: 'add_column', table, column: column(name, type) });
      if (added.status >= 300) {
        cells.push([name, 'FAIL', `add_column ${type} ${added.status}: ${brief(added.json)}`]);
        continue;
      }
      const ins = await call(`/query/v1/${id}/tables/${table}`, { op: 'insert', data: { [name]: value } });
      if (ins.status >= 300) {
        cells.push([name, 'FAIL', `insert ${ins.status}: ${brief(ins.json)}`]);
        continue;
      }
      const list = await call(`/query/v1/${id}/tables/${table}`, { op: 'list', limit: 50 });
      const got = rowsOf(list.json).find((r) => r[name] !== null && r[name] !== undefined)?.[name];
      const described = (await describeTypes(id, table))[name];
      const ok = described === type && got !== undefined && check(got);
      cells.push([name, ok ? 'PASS' : 'FAIL', `described ${described}, read ${JSON.stringify(got)}`]);
    }
    return cells;
  } finally {
    await ddl(id, { op: 'drop_table', table, confirm: true });
  }
}

function judge(engine, [name, verdict, detail]) {
  const gap = GAPS[engine]?.[name];
  if (gap && verdict === 'FAIL') return ['GAP', `${detail} — ${gap}`];
  if (gap) return ['FAIL', `${detail} — now passes: remove the GAPS entry (${gap})`];
  return [verdict, detail];
}

let failed = 0;
for (const [engine, id] of MOUNTS) {
  for (const cell of await probeEngine(engine, id)) {
    const [verdict, detail] = judge(engine, cell);
    if (verdict === 'FAIL') failed += 1;
    console.log(`${verdict.padEnd(4)} ${engine.padEnd(11)} ${cell[0].padEnd(8)} ${detail}`);
  }
}
if (!MOUNTS.length) console.log('SKIP no M249_MOUNTS');
process.exit(failed ? 1 : 0);
