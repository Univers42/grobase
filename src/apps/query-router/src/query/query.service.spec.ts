// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { describe, expect, it } from '@jest/globals';
import { QueryService } from './query.service';

// `resourceIdFromFilter` is a pure private helper (it reads only its argument,
// never `this`), so exercise it through a prototype-only instance — no need for
// the service's heavy DI constructor and its many injected dependencies.
type WithHelper = {
  resourceIdFromFilter(filter: Record<string, unknown> | undefined): string | undefined;
};

describe('QueryService.resourceIdFromFilter', () => {
  const svc = Object.create(QueryService.prototype) as unknown as WithHelper;
  const call = (filter: Record<string, unknown> | undefined) => svc.resourceIdFromFilter(filter);

  it('returns undefined for missing / undefined / null ids', () => {
    expect(call(undefined)).toBeUndefined();
    expect(call({})).toBeUndefined();
    expect(call({ id: null })).toBeUndefined();
  });

  it('passes a string id through unchanged', () => {
    expect(call({ id: 'abc' })).toBe('abc');
  });

  it('stringifies number / boolean / bigint primitives', () => {
    expect(call({ id: 42 })).toBe('42');
    expect(call({ id: true })).toBe('true');
    expect(call({ id: 10n })).toBe('10');
  });

  it('JSON-encodes a composite (object) id', () => {
    expect(call({ id: { a: 1 } })).toBe('{"a":1}');
  });
});
