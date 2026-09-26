/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   feature-flag.spec.ts                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/23 00:00:00 by dlesieur          #+#    #+#             */
/*                                                +#+#+#+#+#+   +#+           */
/* ************************************************************************** */

import { afterEach, describe, expect, it, jest } from '@jest/globals';

jest.mock('./feature-flag', () => {
  const actual = jest.requireActual<typeof import('./feature-flag')>('./feature-flag');
  return { isTruthy: jest.fn(actual.isTruthy) };
});
import { activeContentHeaders } from './active-content';
import { BucketPolicy } from './bucket-policy';
import { isTruthy } from './feature-flag';
import { parseTransform } from './image-transform';
import { UsageMeter } from './usage-meter';

const spy = jest.mocked(isTruthy);

afterEach(() => {
  spy.mockClear();
});

describe('isTruthy (the storage plane flag parser)', () => {
  it('accepts 1/true/yes/on in any case, with surrounding space', () => {
    for (const value of ['1', 'true', 'yes', 'on', 'TRUE', 'Yes', ' on ', '\t1\n', ' ON']) {
      expect(isTruthy(value)).toBe(true);
    }
  });

  it('rejects unset, empty, off spellings and anything else', () => {
    for (const value of [
      undefined,
      '',
      ' ',
      '0',
      'false',
      'no',
      'off',
      'nope',
      'onn',
      '1 1',
      'o n',
    ]) {
      expect(isTruthy(value)).toBe(false);
    }
  });
});

describe('every storage flag gate reads through the one isTruthy', () => {
  it('each caller hands its own flag value to the shared parser', () => {
    parseTransform({}, { STORAGE_TRANSFORMS_ENABLED: 'sentinel-transform' });
    BucketPolicy.fromConfig({ STORAGE_BUCKET_POLICY_ENABLED: 'sentinel-policy' });
    UsageMeter.fromConfig({ STORAGE_METERING: 'sentinel-meter' });
    activeContentHeaders('text/html', { STORAGE_ACTIVE_CONTENT_GUARD_ENABLED: 'sentinel-guard' });
    expect(spy.mock.calls).toEqual([
      ['sentinel-transform'],
      ['sentinel-policy'],
      ['sentinel-meter'],
      ['sentinel-guard'],
    ]);
  });

  it('a spaced/uppercased ON value enables transforms, bucket policy and the guard alike', () => {
    expect(parseTransform({ width: '10' }, { STORAGE_TRANSFORMS_ENABLED: ' YES ' })).toEqual(
      expect.objectContaining({ width: 10 }),
    );
    expect(BucketPolicy.fromConfig({ STORAGE_BUCKET_POLICY_ENABLED: ' On ' })).toBeInstanceOf(
      BucketPolicy,
    );
    expect(
      activeContentHeaders('text/html', { STORAGE_ACTIVE_CONTENT_GUARD_ENABLED: '\tTRUE\n' }),
    ).toHaveProperty('Content-Security-Policy', 'sandbox');
  });

  it('an unset or garbage value keeps every gate OFF', () => {
    for (const value of [undefined, 'nope']) {
      expect(
        parseTransform({ width: '10' }, { STORAGE_TRANSFORMS_ENABLED: value }),
      ).toBeUndefined();
      expect(BucketPolicy.fromConfig({ STORAGE_BUCKET_POLICY_ENABLED: value })).toBeUndefined();
      expect(UsageMeter.fromConfig({ STORAGE_METERING: value })).toBeUndefined();
      expect(
        activeContentHeaders('text/html', { STORAGE_ACTIVE_CONTENT_GUARD_ENABLED: value }),
      ).toEqual({});
    }
  });
});
