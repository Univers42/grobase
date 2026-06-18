// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { describe, expect, it } from '@jest/globals';
import { BadRequestException } from '@nestjs/common';
import { formatNodeId, parseNodeId, toEdgeRecord } from './graph.types';

describe('graph.types node-id helpers', () => {
  it('parseNodeId splits mount:resource:pk (the pk may itself contain colons)', () => {
    expect(parseNodeId('db1:users:42')).toEqual({ dbId: 'db1', resource: 'users', pk: '42' });
    expect(parseNodeId('db1:users:a:b:c')).toEqual({
      dbId: 'db1',
      resource: 'users',
      pk: 'a:b:c',
    });
  });

  it('parseNodeId rejects malformed ids', () => {
    expect(() => parseNodeId('nope')).toThrow(BadRequestException);
    expect(() => parseNodeId(':users:42')).toThrow(BadRequestException);
    expect(() => parseNodeId('db1:users:')).toThrow(BadRequestException);
  });

  it('formatNodeId round-trips with parseNodeId', () => {
    expect(formatNodeId('db1', 'users', '42')).toBe('db1:users:42');
    const id = 'db1:users:a:b';
    const parts = parseNodeId(id);
    expect(formatNodeId(parts.dbId, parts.resource, parts.pk)).toBe(id);
  });

  it('toEdgeRecord coerces a valid row and rejects malformed input', () => {
    expect(toEdgeRecord({ from: 'a', to: 'b' })).toMatchObject({
      from: 'a',
      to: 'b',
      type: 'linked',
      directed: true,
    });
    expect(toEdgeRecord({ from: 1, to: 'b' })).toBeNull();
  });
});
