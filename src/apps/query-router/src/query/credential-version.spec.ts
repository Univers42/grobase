// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { describe, expect, it } from '@jest/globals';
import { credentialVersionFor } from './credential-version';

describe('credentialVersionFor', () => {
  // The Rust data plane keys its per-mount pool on `credential_ref.version`.
  // ONLY a rotated mount (revision >= 2) may fork the pool — every other
  // revision keeps the historical 'live' key, so an unrotated mount is NOT
  // rebuilt at deploy time.
  const notRotated: ReadonlyArray<readonly [unknown, string]> = [
    [undefined, 'live'],
    [null, 'live'],
    [1, 'live'],
    [0, 'live'],
    [-3, 'live'],
    [2.5, 'live'],
    ['7', 'live'],
  ];
  it.each(notRotated)('maps a non-rotation revision %p to "%s"', (revision, expected) => {
    expect(credentialVersionFor(revision)).toBe(expected);
  });

  const rotated: ReadonlyArray<readonly [number, string]> = [
    [2, 'r2'],
    [41, 'r41'],
  ];
  it.each(rotated)('maps a rotated revision %p to "%s"', (revision, expected) => {
    expect(credentialVersionFor(revision)).toBe(expected);
  });
});
