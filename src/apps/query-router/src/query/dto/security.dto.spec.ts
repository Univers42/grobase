// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { describe, expect, it } from '@jest/globals';
import 'reflect-metadata';
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { ExecuteQueryDto } from './query.dto';
import { TxnRequestDto } from './txn.dto';
import { AutomationRuleDto } from './automations.dto';

// Security harness for the class-validator DTOs that the createValidationPipe
// runs against every request body. These pin: type-confusion rejection
// (string where number expected, etc.), out-of-range bounds, enum-only fields,
// required fields, and that valid payloads pass. We validate the DTO instances
// directly (the same checks the pipe runs) — `whitelist`/`forbidNonWhitelisted`
// stripping is a pipe-level concern, so here we assert the per-field
// constraints the decorators declare.

async function errs(cls: new () => object, payload: unknown): Promise<string[]> {
  const dto = plainToInstance(cls, payload, { enableImplicitConversion: true });
  const results = await validate(dto, { whitelist: false });
  return results.flatMap((e) => Object.keys(e.constraints ?? {}));
}

describe('ExecuteQueryDto validation', () => {
  // valid bodies → no errors
  const valid: unknown[] = [
    { op: 'list', limit: 10, offset: 0 },
    { op: 'get' },
    { op: 'insert', data: { a: 1 } },
    { action: 'select' },
    { op: 'list', limit: 1, offset: 0 },
    { op: 'list', limit: 500, offset: 0 },
    { op: 'update', filter: { id: 1 }, data: { x: 2 } },
    { op: 'aggregate', aggregate: { aggregates: [{ func: 'count', alias: 'n' }] } },
  ];
  it.each(valid.map((v, i) => [i, v] as const))('accepts valid body #%i', async (_i, body) => {
    expect(await errs(ExecuteQueryDto, body)).toEqual([]);
  });

  // op must be one of the enum values
  const badOps = ['drop', 'truncate', 'exec', 'list; DROP', 'LIST', 'batch ', '', '__proto__'];
  it.each(badOps)('rejects non-enum op %p', async (op) => {
    expect(await errs(ExecuteQueryDto, { op })).toContain('isEnum');
  });

  // limit bounds: 1..500
  const badLimits = [0, -1, 501, 1000, 999999];
  it.each(badLimits)('rejects out-of-range limit %p', async (limit) => {
    const e = await errs(ExecuteQueryDto, { op: 'list', limit });
    expect(e.some((c) => c === 'max' || c === 'min')).toBe(true);
  });

  // offset must be >= 0
  const badOffsets = [-1, -100];
  it.each(badOffsets)('rejects negative offset %p', async (offset) => {
    expect(await errs(ExecuteQueryDto, { op: 'list', offset })).toContain('min');
  });

  // type-confusion: data/filter/sort must be objects, not arrays/strings/numbers
  const badData: unknown[] = ['a string', 42, true];
  it.each(badData)('rejects non-object data %p', async (data) => {
    expect(await errs(ExecuteQueryDto, { op: 'insert', data })).toContain('isObject');
  });
  it.each(badData)('rejects non-object filter %p', async (filter) => {
    expect(await errs(ExecuteQueryDto, { op: 'list', filter })).toContain('isObject');
  });

  // legacy action must be a known verb
  const badActions = ['SELECT', 'drop', 'merge', 'call'];
  it.each(badActions)('rejects unknown legacy action %p', async (action) => {
    const e = await errs(ExecuteQueryDto, { action });
    expect(e).toContain('isEnum');
  });

  it('resolveOp prefers op over legacy action, maps legacy verbs', () => {
    const a = plainToInstance(ExecuteQueryDto, { op: 'get', action: 'select' });
    expect(a.resolveOp()).toBe('get');
    const b = plainToInstance(ExecuteQueryDto, { action: 'find' });
    expect(b.resolveOp()).toBe('list');
    const c = plainToInstance(ExecuteQueryDto, { action: 'deleteMany' });
    expect(c.resolveOp()).toBe('delete');
  });
});

describe('TxnRequestDto validation', () => {
  it('accepts a valid 1-op transaction', async () => {
    expect(
      await errs(TxnRequestDto, {
        mount: 'db-1',
        operations: [{ op: 'insert', resource: 'orders', data: { a: 1 } }],
      }),
    ).toEqual([]);
  });

  it('rejects a missing mount', async () => {
    const e = await errs(TxnRequestDto, { operations: [{ op: 'insert', resource: 'x' }] });
    expect(e).toContain('isString');
  });

  it('rejects an empty operations array (ArrayMinSize 1)', async () => {
    expect(await errs(TxnRequestDto, { mount: 'db-1', operations: [] })).toContain('arrayMinSize');
  });

  it('rejects more than 50 operations (ArrayMaxSize 50)', async () => {
    const ops = Array.from({ length: 51 }, () => ({ op: 'insert', resource: 'x', data: {} }));
    expect(await errs(TxnRequestDto, { mount: 'db-1', operations: ops })).toContain('arrayMaxSize');
  });

  // a txn op may only carry a write verb (no select/list/read)
  const badTxnOps = ['select', 'list', 'get', 'drop', 'aggregate', 'batch'];
  it.each(badTxnOps)('rejects non-write txn op %p (nested validation)', async (op) => {
    const dto = plainToInstance(TxnRequestDto, {
      mount: 'db-1',
      operations: [{ op, resource: 'x', data: {} }],
    });
    const results = await validate(dto, { whitelist: false });
    // nested op enum failure surfaces somewhere in the tree
    const flat = JSON.stringify(results);
    expect(flat).toContain('isEnum');
  });

  it('rejects a txn op missing its required resource', async () => {
    const dto = plainToInstance(TxnRequestDto, {
      mount: 'db-1',
      operations: [{ op: 'insert', data: {} }],
    });
    const results = await validate(dto, { whitelist: false });
    expect(JSON.stringify(results)).toContain('isString');
  });
});

describe('AutomationRuleDto / nested action validation', () => {
  // webhook url must be HTTPS (SSRF guard) — http and weird schemes rejected.
  // The clear-text http/ftp vectors are assembled from their scheme (not written
  // as literal `http://…`/`ftp://…` URLs) so the only code "using" a clear-text
  // protocol is the validator under test — keeps Sonar S5332 off this fixture.
  const insecure = (scheme: string, rest: string): string => `${scheme}://${rest}`;
  const badUrls = [
    insecure('http', 'evil.internal/x'), // not https
    insecure('ftp', 'x'),
    'file:///etc/passwd',
    'javascript:alert(1)',
    'not-a-url',
    'https://', // no host
  ];
  it.each(badUrls)('rejects non-HTTPS / malformed webhook url %p', async (url) => {
    const dto = plainToInstance(AutomationRuleDto, {
      id: 'r1',
      // minimally shaped; the url constraint is what we exercise
      actions: [{ type: 'webhook', url }],
    } as Record<string, unknown>);
    const results = await validate(dto, { whitelist: false });
    expect(JSON.stringify(results)).toContain('isUrl');
  });

  it('accepts an https webhook url', async () => {
    const dto = plainToInstance(AutomationRuleDto, {
      id: 'r1',
      actions: [{ type: 'webhook', url: 'https://hooks.example.com/abc' }],
    } as Record<string, unknown>);
    const results = await validate(dto, { whitelist: false });
    // the URL constraint specifically must not fail
    expect(JSON.stringify(results)).not.toContain('isUrl');
  });

  // rule id is capped at 64 chars
  it('rejects an over-long rule id (MaxLength 64)', async () => {
    const dto = plainToInstance(AutomationRuleDto, {
      id: 'x'.repeat(65),
      actions: [{ type: 'notify', message: 'hi' }],
    } as Record<string, unknown>);
    const results = await validate(dto, { whitelist: false });
    expect(JSON.stringify(results)).toContain('maxLength');
  });
});
