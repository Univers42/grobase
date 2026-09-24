/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   automations.pin.spec.ts                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/23 00:00:00 by dlesieur          #+#    #+#             */
/*                                                +#+#+#+#+#+   +#+           */
/* ************************************************************************** */

import { afterEach, describe, expect, it, jest } from '@jest/globals';
import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { EventEmitter } from 'node:events';
import https from 'node:https';

jest.mock('node:dns/promises', () => ({
  lookup: async (host: string) =>
    host === 'bench.example'
      ? [{ address: '198.18.0.1', family: 4 }]
      : [{ address: '93.184.216.34', family: 4 }],
}));
jest.mock('node:dns', () => {
  const hosts: Record<string, Array<{ address: string; family: number }>> = {
    'public.example': [{ address: '93.184.216.34', family: 4 }],
    'private.example': [{ address: '10.0.0.7', family: 4 }],
    'loopback6.example': [{ address: '::1', family: 6 }],
    'ula.example': [{ address: 'fd00::1', family: 6 }],
    'mixed.example': [
      { address: '93.184.216.34', family: 4 },
      { address: '10.0.0.7', family: 4 },
    ],
    'rebind.example': [{ address: '10.0.0.7', family: 4 }],
    'bench.example': [{ address: '198.18.0.1', family: 4 }],
    'nat64.example': [{ address: '64:ff9b::a9fe:a9fe', family: 6 }],
    'mapped.example': [{ address: '::ffff:c612:1', family: 6 }],
    'mapped-public.example': [{ address: '::ffff:808:808', family: 6 }],
    'nat64-public.example': [{ address: '64:ff9b::808:808', family: 6 }],
  };
  return {
    ...jest.requireActual<typeof import('node:dns')>('node:dns'),
    lookup: (host: string, _options: unknown, cb: (err: null, records: unknown) => void) =>
      setImmediate(() => cb(null, hosts[host] ?? [])),
  };
});
import { AutomationsService } from './automations.service';
import { isPrivateAddress, isPrivateAddressStrict, publicOnlyLookup } from './webhook-ssrf';
import type { AutomationRuleDto } from './dto/automations.dto';

type LookupResult = { err: NodeJS.ErrnoException | null; address: unknown; family?: number };

/** Runs publicOnlyLookup and collects its callback arguments. */
function resolveVia(host: string, all: boolean): Promise<LookupResult> {
  return new Promise((done) =>
    publicOnlyLookup(host, all ? { all: true } : {}, (err, address, family) =>
      done({ err, address, family }),
    ),
  );
}

/** A service with the pin flag set to `flag` and one primed webhook rule for `url`. */
function makeService(flag: string | undefined, url: string): AutomationsService {
  const config = {
    get: (key: string) => (key === 'AUTOMATION_WEBHOOK_IP_PIN_ENABLED' ? flag : undefined),
  } as unknown as ConfigService;
  const service = new AutomationsService(config);
  const rule: AutomationRuleDto = {
    id: 'r1',
    name: 'Hook',
    enabled: true,
    table: 'orders',
    trigger: 'row_updated',
    actions: [{ type: 'webhook', url }],
  };
  (
    service as unknown as { cache: Map<string, { rules: AutomationRuleDto[]; expiresAt: number }> }
  ).cache.set('t1:db1', { rules: [rule], expiresAt: Date.now() + 60_000 });
  return service;
}

/** Fires the primed rule once through the public write-path entry point. */
function fire(service: AutomationsService): Promise<void> {
  return service.runForWrite(
    {
      dbId: 'db1',
      tenantId: 't1',
      userId: 'u1',
      table: 'orders',
      op: 'update',
      row: { id: 7 },
      pk: 7,
    },
    jest.fn(async () => undefined),
    jest.fn(async () => undefined),
  );
}

/** Replaces https.request with an in-memory transport: answers `status`, or emits `fail`. */
function fakeTransport(outcome: { status?: number; fail?: Error }) {
  const res = Object.assign(new EventEmitter(), {
    statusCode: outcome.status,
    destroy: jest.fn(),
  });
  const seen = {
    bodies: [] as string[],
    errorListeners: -1,
    options: {} as Record<string, unknown>,
  };
  const request = (_url: string, options: Record<string, unknown>, onRes: (r: unknown) => void) => {
    seen.options = options;
    const req = Object.assign(new EventEmitter(), {
      end: (body: string) => {
        seen.bodies.push(body);
        seen.errorListeners = req.listenerCount('error');
        setImmediate(() => (outcome.fail ? req.emit('error', outcome.fail) : onRes(res)));
      },
    });
    return req;
  };
  const spy = jest
    .spyOn(https, 'request')
    .mockImplementation(request as unknown as typeof https.request);
  return { res, seen, spy };
}

afterEach(() => {
  jest.restoreAllMocks();
});

describe('publicOnlyLookup (connect-time SSRF guard)', () => {
  it('hands back a public IPv4 in both the all:true and the single-address shape', async () => {
    const many = await resolveVia('public.example', true);
    expect(many.err).toBeNull();
    expect(many.address).toEqual([{ address: '93.184.216.34', family: 4 }]);
    const one = await resolveVia('public.example', false);
    expect(one).toEqual({ err: null, address: '93.184.216.34', family: 4 });
  });

  it('refuses private IPv4, IPv6 loopback, ULA, mixed and empty answers with EBLOCKED', async () => {
    for (const host of [
      'private.example',
      'loopback6.example',
      'ula.example',
      'mixed.example',
      'nxdomain.example',
    ]) {
      for (const all of [true, false]) {
        const out = await resolveVia(host, all);
        expect(out.err?.code).toBe('EBLOCKED');
      }
    }
  });

  it('uses the strict ranges: benchmarking, NAT64 and hex-mapped internal answers are EBLOCKED', async () => {
    for (const host of ['bench.example', 'nat64.example', 'mapped.example']) {
      for (const all of [true, false]) {
        expect((await resolveVia(host, all)).err?.code).toBe('EBLOCKED');
      }
    }
  });

  it('judges mapped and NAT64 answers by the public IPv4 they embed', async () => {
    expect(await resolveVia('mapped-public.example', false)).toEqual({
      err: null,
      address: '::ffff:808:808',
      family: 6,
    });
    expect((await resolveVia('nat64-public.example', true)).err).toBeNull();
  });
});

describe('webhook delivery with AUTOMATION_WEBHOOK_IP_PIN_ENABLED', () => {
  it('ON: a name that re-resolves to a private address is refused at connect, never fetched', async () => {
    const fetchSpy = jest.spyOn(globalThis, 'fetch');
    const requestSpy = jest.spyOn(https, 'request');
    const warn = jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    await fire(makeService('1', 'https://rebind.example/hook'));
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(requestSpy).toHaveBeenCalledTimes(1);
    expect(requestSpy.mock.calls[0][1]).toMatchObject({ lookup: publicOnlyLookup, agent: false });
    expect(warn).toHaveBeenCalledTimes(1);
    expect(String(warn.mock.calls[0][0])).toMatch(/webhook failed: .*EBLOCKED/);
  });

  it('ON: a request error rejects through a listener registered before end()', async () => {
    const warn = jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    const blocked = Object.assign(new Error('connect EBLOCKED'), { code: 'EBLOCKED' });
    const { seen } = fakeTransport({ fail: blocked });
    await fire(makeService('true', 'https://public.example/hook'));
    expect(seen.errorListeners).toBeGreaterThanOrEqual(1);
    expect(String(warn.mock.calls[0][0])).toContain('connect EBLOCKED');
  });

  it('ON: destroys a response whose body never ends once the status is known', async () => {
    const warn = jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    const { res, seen } = fakeTransport({ status: 200 });
    await fire(makeService('on', 'https://public.example/hook'));
    expect(res.destroy).toHaveBeenCalledTimes(1);
    expect(seen.bodies).toHaveLength(1);
    expect(warn).not.toHaveBeenCalled();
  });

  it('ON: a 3xx is refused like the fetch path redirect:error', async () => {
    const warn = jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    const { res } = fakeTransport({ status: 302 });
    await fire(makeService('1', 'https://public.example/hook'));
    expect(res.destroy).toHaveBeenCalledTimes(1);
    expect(String(warn.mock.calls[0][0])).toContain('webhook redirect refused (302)');
  });

  it('OFF (unset): today fetch path with the original URL; https.request is never used', async () => {
    const fetchSpy = jest
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(new Response(null, { status: 200 }));
    const { spy, seen } = fakeTransport({ status: 200 });
    await fire(makeService(undefined, 'https://public.example/hook'));
    expect(spy).not.toHaveBeenCalled();
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const [target, init] = fetchSpy.mock.calls[0];
    expect(target).toBe('https://public.example/hook');
    expect(init).toMatchObject({
      method: 'POST',
      redirect: 'error',
      headers: { 'Content-Type': 'application/json' },
    });
    await fire(makeService('1', 'https://public.example/hook'));
    const { ts: offTs, ...offBody } = JSON.parse(String(init?.body));
    const { ts: onTs, ...onBody } = JSON.parse(seen.bodies[0]);
    expect(onBody).toEqual(offBody);
    expect(typeof offTs).toBe('string');
    expect(typeof onTs).toBe('string');
    expect(seen.options).toMatchObject({
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(seen.bodies[0]),
      },
    });
  });
});

/** Addresses only the strict (flag-ON) classifier refuses; `isPrivateAddress` (flag OFF) calls them public. */
const WIDENED = [
  '192.0.0.1',
  '192.0.0.170',
  '192.0.2.1',
  '198.18.0.1',
  '198.19.255.254',
  '198.51.100.7',
  '203.0.113.9',
  '224.0.0.1',
  '239.255.255.250',
  '240.0.0.1',
  '255.255.255.255',
  'fe90::1',
  'fea0::1',
  'febf:ffff::1',
  'FE9A::1',
  'fe90::1%eth0',
  'fec0::1',
  '64:ff9b::a9fe:a9fe',
  '64:ff9b::10.0.0.1',
  '0064:ff9b::7f00:1',
  '64:ff9b:1::1',
  '2002:c0a8:101::1',
  '2002::1',
  '2001::1',
  '2001:2::1',
  '2001:db8::1',
  '100::1',
  '4000::1',
  '::ffff:198.18.0.1',
  '::ffff:224.0.0.1',
];

/** What `isPrivateAddress` already refused at HEAD; the strict classifier must refuse it too. */
const LEGACY_BLOCKED = [
  '127.0.0.1',
  '10.0.0.5',
  '192.168.1.10',
  '172.16.0.1',
  '169.254.169.254',
  '100.64.0.1',
  '0.0.0.0',
  '::1',
  '::',
  'fe80::1',
  'fc00::1',
  'fd12:3456::1',
  'ff02::1',
  '::ffff:169.254.169.254',
  '::ffff:a9fe:a9fe',
  '::ffff:c612:1',
  '::ffff:e000:1',
  '::a9fe:a9fe',
  '::ffff:0:a9fe:a9fe',
  'not-an-ip',
];

/** Public under both classifiers, including the edges just outside each widened range. */
const PUBLIC_BOTH = [
  '93.184.216.34',
  '1.1.1.1',
  '8.8.8.8',
  '192.0.1.1',
  '192.0.3.1',
  '198.17.255.255',
  '198.20.0.1',
  '198.51.101.1',
  '203.0.114.1',
  '223.255.255.255',
  '2606:4700:4700::1111',
  '2001:200::1',
  '2001:db9::1',
  '2003::1',
  '3fff:ffff::1',
  '::ffff:8.8.8.8',
  '64:ff9b::808:808',
  '64:ff9b::8.8.8.8',
];

describe('isPrivateAddressStrict (flag-ON classifier) vs isPrivateAddress (flag OFF)', () => {
  it('ON refuses every widened range; OFF still calls each of them public, as at HEAD', () => {
    for (const ip of WIDENED) {
      expect([ip, isPrivateAddressStrict(ip)]).toEqual([ip, true]);
      expect([ip, isPrivateAddress(ip)]).toEqual([ip, false]);
    }
  });

  it('ON refuses everything OFF refuses, hex-mapped internal IPv4 included', () => {
    for (const ip of LEGACY_BLOCKED) {
      expect([ip, isPrivateAddress(ip)]).toEqual([ip, true]);
      expect([ip, isPrivateAddressStrict(ip)]).toEqual([ip, true]);
    }
  });

  it('ON and OFF both allow public addresses and the edges of each widened range', () => {
    for (const ip of PUBLIC_BOTH) {
      expect([ip, isPrivateAddress(ip)]).toEqual([ip, false]);
      expect([ip, isPrivateAddressStrict(ip)]).toEqual([ip, false]);
    }
  });

  it('ON judges both spellings of a mapped IPv4 by that IPv4; OFF refuses the hex one wholesale', () => {
    expect(isPrivateAddressStrict('::ffff:808:808')).toBe(false);
    expect(isPrivateAddressStrict('::ffff:8.8.8.8')).toBe(false);
    expect(isPrivateAddress('::ffff:808:808')).toBe(true);
    expect(isPrivateAddress('::ffff:8.8.8.8')).toBe(false);
  });

  it('ON fails closed on anything that is not an IP literal', () => {
    for (const ip of ['', 'example.com', '1.2.3.04', '::ffff:1.2.3.256', '2001:db8::1::1']) {
      expect([ip, isPrivateAddressStrict(ip)]).toEqual([ip, true]);
    }
  });
});

describe('webhook pre-check classifier follows the pin flag', () => {
  const literals = [
    'https://198.18.0.1/x',
    'https://224.0.0.1/x',
    'https://[64:ff9b::a9fe:a9fe]/x',
    'https://[fe90::1]/x',
    'https://[2002:c0a8:101::1]/x',
  ];

  it('ON: widened-range literals and names are refused before any transport runs', async () => {
    const warn = jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    const fetchSpy = jest.spyOn(globalThis, 'fetch');
    const { spy } = fakeTransport({ status: 200 });
    for (const url of [...literals, 'https://[::ffff:198.18.0.1]/x']) {
      await fire(makeService('1', url));
    }
    await fire(makeService('1', 'https://bench.example/x'));
    expect(spy).not.toHaveBeenCalled();
    expect(fetchSpy).not.toHaveBeenCalled();
    const messages = warn.mock.calls.map((call) => String(call[0]));
    expect(messages).toHaveLength(literals.length + 2);
    expect(messages.slice(0, -1).every((m) => m.includes('(non-public address)'))).toBe(true);
    expect(messages[messages.length - 1]).toContain(
      'resolves to non-public address): bench.example',
    );
  });

  it('OFF: the same targets still pass the pre-check and reach fetch, as at HEAD', async () => {
    const warn = jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    const fetchSpy = jest
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(new Response(null, { status: 200 }));
    for (const url of [...literals, 'https://bench.example/x']) {
      await fire(makeService(undefined, url));
    }
    expect(fetchSpy.mock.calls.map((call) => call[0])).toEqual([
      ...literals,
      'https://bench.example/x',
    ]);
    expect(warn).not.toHaveBeenCalled();
  });
});

describe('AUTOMATION_WEBHOOK_IP_PIN_ENABLED parsing (trimmed, like the storage flags)', () => {
  it('spaced and mixed-case ON spellings select the pinned transport', async () => {
    const values = [' 1', '1 ', ' true ', '\tON\n', ' Yes'];
    const fetchSpy = jest.spyOn(globalThis, 'fetch');
    const { spy } = fakeTransport({ status: 200 });
    for (const value of values) {
      await fire(makeService(value, 'https://public.example/hook'));
    }
    expect(spy).toHaveBeenCalledTimes(values.length);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('unset, blank and garbage values keep the fetch path', async () => {
    const values = [undefined, '', ' ', '0', 'off', 'nope', 'o n'];
    const fetchSpy = jest
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(new Response(null, { status: 200 }));
    const { spy } = fakeTransport({ status: 200 });
    for (const value of values) {
      await fire(makeService(value, 'https://public.example/hook'));
    }
    expect(spy).not.toHaveBeenCalled();
    expect(fetchSpy).toHaveBeenCalledTimes(values.length);
  });
});
