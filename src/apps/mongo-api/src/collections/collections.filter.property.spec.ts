import { describe, expect, it, jest } from '@jest/globals';
import { BadRequestException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import type { MongoService } from '@mini-baas/database';
import type { Counter } from 'prom-client';
import { CollectionsService } from './collections.service';

// Property tests for the `?filter=` guard (M-6): random JSON filters, built as
// TEXT so duplicate and `__proto__` keys reach the service exactly as a client
// can send them, checked against an independent oracle. Seeded and
// deterministic; FILTER_PROPERTY_SEED=<n> replays one seed.
//
// Ponytail: the generator draws keys from a fixed pool (operators, dotted,
// prototype names, owner/_id, unicode, empty) — a key shape outside the pool
// is not explored, and there is no shrinking: a failure prints the filter.

type Tree =
  | { kind: 'obj'; entries: Array<[string, Tree]> }
  | { kind: 'arr'; items: Tree[] }
  | { kind: 'leaf'; value: string | number | boolean | null };

const KEYS = [
  'a',
  'name',
  'x_y',
  'tags',
  '__proto__',
  'constructor',
  'toString',
  '_id',
  'owner_id',
  '$ne',
  '$where',
  '$gt',
  'a.b',
  '.',
  '$',
  '',
  'é',
  ' ',
  'hasOwnProperty',
];
const LEAVES = [0, 1, -1, 3.5, 'x', '$where', '$ne', 'a.b', '', true, false, null];
const RUNS = 2000;

/** mulberry32 — a tiny seeded PRNG so every run is reproducible. */
function prng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** pick returns a uniformly chosen element of xs. */
function pick<T>(rnd: () => number, xs: readonly T[]): T {
  return xs[Math.floor(rnd() * xs.length)];
}

/** gen builds a random JSON tree of at most `depth` levels. */
function gen(rnd: () => number, depth: number): Tree {
  const roll = rnd();
  if (depth <= 0 || roll < 0.4) return { kind: 'leaf', value: pick(rnd, LEAVES) };
  const n = Math.floor(rnd() * 4);
  if (roll < 0.6)
    return { kind: 'arr', items: Array.from({ length: n }, () => gen(rnd, depth - 1)) };
  return {
    kind: 'obj',
    entries: Array.from({ length: n }, () => [pick(rnd, KEYS), gen(rnd, depth - 1)]),
  };
}

/** text serialises a tree as JSON, keeping duplicate and `__proto__` keys. */
function text(t: Tree): string {
  if (t.kind === 'leaf') return JSON.stringify(t.value);
  if (t.kind === 'arr') return `[${t.items.map(text).join(',')}]`;
  return `{${t.entries.map(([k, v]) => `${JSON.stringify(k)}:${text(v)}`).join(',')}}`;
}

/** lastWins applies JSON.parse's duplicate-key rule: first position, last value. */
function lastWins(entries: Array<[string, Tree]>): Array<[string, Tree]> {
  const m = new Map<string, Tree>();
  for (const [k, v] of entries) m.set(k, v);
  return [...m.entries()];
}

/** operatorKey reports a key Mongo would read as an operator or a path. */
function operatorKey(k: string): boolean {
  return k.startsWith('$') || k.includes('.');
}

/** unsafe reports whether any key at any depth of a value is an operator key. */
function unsafe(t: Tree): boolean {
  if (t.kind === 'arr') return t.items.some(unsafe);
  if (t.kind === 'leaf') return false;
  return lastWins(t.entries).some(([k, v]) => operatorKey(k) || unsafe(v));
}

/** rejected is the oracle: whether the service must refuse this filter. */
function rejected(t: Tree): boolean {
  if (t.kind !== 'obj') return true;
  return lastWins(t.entries).some(
    ([k, v]) => k === '' || k === '_id' || k === 'owner_id' || operatorKey(k) || unsafe(v),
  );
}

/** canon serialises a parsed value with object keys sorted (own keys only). */
function canon(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canon).join(',')}]`;
  if (v === null || typeof v !== 'object') return JSON.stringify(v);
  const o = v as Record<string, unknown>;
  return `{${Object.keys(o)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${canon(o[k])}`)
    .join(',')}}`;
}

/** expectedQuery is the driver query an accepted filter must produce, canonical. */
function expectedQuery(t: Tree & { kind: 'obj' }, userId: string): string {
  const fields = lastWins(t.entries)
    .filter(([k]) => k !== '__proto__')
    .map(([k, v]) => `${JSON.stringify(k)}:${text(v)}`);
  return canon(JSON.parse(`{${[`"owner_id":${JSON.stringify(userId)}`, ...fields].join(',')}}`));
}

/** harness returns a service whose driver records every find() query. */
function harness() {
  const queries: Array<Record<string, unknown>> = [];
  const cursor = {
    sort: () => cursor,
    skip: () => cursor,
    limit: () => cursor,
    toArray: async () => [],
  };
  const collection = {
    find: (q: Record<string, unknown>) => (queries.push(q), cursor),
    countDocuments: async () => 0,
  };
  const db = { collection: () => collection };
  const mongo = { getDb: () => db } as unknown as MongoService;
  const config = { get: (_k: string, def?: string) => def } as unknown as ConfigService;
  const counter = { inc: jest.fn() } as unknown as Counter<string>;
  return { service: new CollectionsService(mongo, config, counter), queries };
}

/** seeds returns the seeds to run: the env override alone, else a fixed set. */
function seeds(): number[] {
  const one = Number(process.env.FILTER_PROPERTY_SEED);
  return Number.isInteger(one) ? [one] : [1, 42, 2026];
}

/** check runs one filter through findAll and asserts the oracle's verdict. */
async function check(t: Tree, userId: string): Promise<void> {
  const h = harness();
  const filter = text(t);
  const run = h.service.findAll('notes', userId, { limit: 10, offset: 0, filter });
  if (rejected(t)) {
    await expect(run).rejects.toBeInstanceOf(BadRequestException);
    expect(h.queries).toHaveLength(0);
    return;
  }
  await run;
  expect(h.queries[0].owner_id).toBe(userId);
  expect({ filter, query: canon(h.queries[0]) }).toEqual({
    filter,
    query: expectedQuery(t as Tree & { kind: 'obj' }, userId),
  });
}

describe('CollectionsService filter guard — properties (M-6)', () => {
  it.each(seeds())(
    'seed %p: refuses exactly the operator filters; an accepted one keeps the owner',
    async (seed) => {
      const rnd = prng(seed);
      for (let i = 0; i < RUNS; i++) {
        const root: Tree = rnd() < 0.9 ? { kind: 'obj', entries: [] } : gen(rnd, 1);
        if (root.kind === 'obj') {
          root.entries = Array.from({ length: 1 + Math.floor(rnd() * 3) }, () => [
            pick(rnd, KEYS),
            gen(rnd, 4),
          ]);
        }
        await check(root, `user-${seed}-${i}`);
      }
    },
  );

  it('a filter nested 20000 levels deep answers 400 or runs — never another error', async () => {
    const h = harness();
    const filter = `{"a":${'['.repeat(20000)}${']'.repeat(20000)}}`;
    const outcome = await h.service
      .findAll('notes', 'u-deep', { limit: 10, offset: 0, filter })
      .then(
        () => 'ran',
        (e: unknown) => (e instanceof BadRequestException ? '400' : String(e)),
      );
    expect(['ran', '400']).toContain(outcome);
    expect(h.queries.every((q) => q.owner_id === 'u-deep')).toBe(true);
  });
});
