// guards.ts — runtime type guards that replace `any`. Untrusted JSON (API
// responses, window globals) is narrowed through these before use.

/** isRecord narrows an unknown value to a string-keyed object. */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** asString returns a string for any scalar (string/number/bigint/boolean), else
 *  the fallback (''). SQL engines return numeric ids (bigint identity columns) the
 *  app uses as string ids — narrowing must coerce them, not drop them to ''. */
export function asString(value: unknown, fallback = ''): string {
  if (typeof value === 'string') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  if (typeof value === 'bigint' || typeof value === 'boolean') return String(value);
  return fallback;
}

/** asNumber coerces strings/numbers to a finite number, else the fallback (0). */
export function asNumber(value: unknown, fallback = 0): number {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim() !== '') {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
  }
  return fallback;
}

/** asBool narrows truthy/“true”/1 to a boolean, else the fallback (false). */
export function asBool(value: unknown, fallback = false): boolean {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'string') return value === 'true' || value === '1';
  if (typeof value === 'number') return value === 1;
  return fallback;
}

/** asArray returns the value when it is an array, else an empty array. */
export function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}
