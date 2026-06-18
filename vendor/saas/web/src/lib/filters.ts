// filters.ts — data-plane `$`-operator filter helpers. The query router accepts a
// filter map of {column: {$op: value}}; these build the common operators so call
// sites stay declarative.

/** Filter is the data-plane filter map: each column maps to an operator object
 *  ({$op: value}) or a bare scalar equality (used for id keys — see eq). */
export type Filter = Record<string, Record<string, unknown> | string | number | boolean>;

/** ID_KEYS are passed as a bare equality, never {$eq}. The Mongo data plane only
 *  coerces a 24-hex string to an ObjectId when `_id`/`id` is a bare scalar (a
 *  {$eq} wrapper hides the string and the match misses); Postgres accepts the bare
 *  equality just the same, so this is engine-agnostic. */
const ID_KEYS = new Set(['_id', 'id']);

/** eq builds {col: {$eq: value}} from a plain {col: value} map — except id keys,
 *  which stay bare so the Mongo ObjectId-coercion path matches. */
export function eq(where: Record<string, unknown>): Filter {
  const filter: Filter = {};
  for (const [k, v] of Object.entries(where)) {
    filter[k] = ID_KEYS.has(k) ? (v as string | number | boolean) : { $eq: v };
  }
  return filter;
}

/** gte builds {col: {$gte: value}}. */
export function gte(col: string, value: unknown): Filter {
  return { [col]: { $gte: value } };
}

/** inList builds {col: {$in: values}}. */
export function inList(col: string, values: readonly unknown[]): Filter {
  return { [col]: { $in: [...values] } };
}

/** ilike builds {col: {$ilike: `%term%`}} for case-insensitive substring search. */
export function ilike(col: string, term: string): Filter {
  return { [col]: { $ilike: `%${term}%` } };
}

/** merge combines several filter fragments into one map (later keys win). */
export function merge(...parts: Filter[]): Filter {
  return Object.assign({}, ...parts);
}
