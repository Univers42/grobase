/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   automations.service.spec.ts                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/10 12:00:00 by dlesieur          #+#    #+#             */
/*                                                +#+#+#+#+#+   +#+           */
/* ************************************************************************** */

// The repo's jest setup does not ship `@types/jest` — import globals explicitly.
import { describe, expect, it, jest } from '@jest/globals';
import { ConfigService } from '@nestjs/config';
import { AutomationsService, evaluateCondition, isPrivateAddress, type AutomationWriteEvent } from './automations.service';
import type { AutomationRuleDto } from './dto/automations.dto';

function makeService(rules: AutomationRuleDto[]): AutomationsService {
  const service = new AutomationsService({ get: () => undefined } as unknown as ConfigService);
  // Prime the TTL cache so runForWrite never touches Postgres in unit tests.
  (service as unknown as { cache: Map<string, { rules: AutomationRuleDto[]; expiresAt: number }> })
    .cache.set('t1:db1', { rules, expiresAt: Date.now() + 60_000 });
  return service;
}

function rule(overrides: Partial<AutomationRuleDto>): AutomationRuleDto {
  return {
    id: 'r1', name: 'Rule', enabled: true, table: 'orders',
    trigger: 'row_updated', actions: [{ type: 'notify', message: 'hi' }],
    ...overrides,
  };
}

function event(overrides: Partial<AutomationWriteEvent> = {}): AutomationWriteEvent {
  return {
    dbId: 'db1', tenantId: 't1', userId: 'u1', table: 'orders',
    op: 'update', row: { id: 7, status: 'shipped' }, pk: 7,
    ...overrides,
  };
}

describe('evaluateCondition', () => {
  it('covers the operator matrix', () => {
    const row = { status: 'shipped', total: '250', note: '' };
    expect(evaluateCondition(row, { column: 'status', operator: 'equals', value: 'shipped' })).toBe(true);
    expect(evaluateCondition(row, { column: 'status', operator: 'not_equals', value: 'open' })).toBe(true);
    expect(evaluateCondition(row, { column: 'status', operator: 'contains', value: 'SHIP' })).toBe(true);
    expect(evaluateCondition(row, { column: 'total', operator: 'greater_than', value: 100 })).toBe(true);
    expect(evaluateCondition(row, { column: 'total', operator: 'less_than', value: 100 })).toBe(false);
    expect(evaluateCondition(row, { column: 'note', operator: 'is_empty' })).toBe(true);
    expect(evaluateCondition(row, { column: 'missing', operator: 'is_not_empty' })).toBe(false);
    // engines disagree on wire types: numeric string == number
    expect(evaluateCondition(row, { column: 'total', operator: 'equals', value: 250 })).toBe(true);
  });
});

describe('AutomationsService.runForWrite', () => {
  it('runs matching enabled rules only (table + trigger + condition)', async () => {
    const notify = jest.fn(async () => undefined);
    const execute = jest.fn(async () => undefined);
    const service = makeService([
      rule({ id: 'match', trigger: 'row_updated' }),
      rule({ id: 'wrong-table', table: 'tickets' }),
      rule({ id: 'wrong-trigger', trigger: 'row_deleted' }),
      rule({ id: 'disabled', enabled: false }),
      rule({ id: 'cond-miss', condition: { column: 'status', operator: 'equals', value: 'open' } }),
    ]);
    await service.runForWrite(event(), execute, notify);
    expect(notify).toHaveBeenCalledTimes(1);
    expect(execute).not.toHaveBeenCalled();
  });

  it('set_property re-enters through the injected executor with the row pk', async () => {
    const execute = jest.fn(async () => undefined);
    const service = makeService([
      rule({ actions: [{ type: 'set_property', column: 'flag', value: 'on' }] }),
    ]);
    await service.runForWrite(event(), execute, jest.fn(async () => undefined));
    expect(execute).toHaveBeenCalledWith('orders', { flag: 'on' }, { id: 7 });
  });

  it('upsert satisfies both row_added and row_updated triggers', async () => {
    const notify = jest.fn(async () => undefined);
    const service = makeService([
      rule({ id: 'a', trigger: 'row_added' }),
      rule({ id: 'b', trigger: 'row_updated' }),
    ]);
    await service.runForWrite(event({ op: 'upsert' }), jest.fn(async () => undefined), notify);
    expect(notify).toHaveBeenCalledTimes(2);
  });

  it('webhooks reject private/internal targets (SSRF guard)', async () => {
    // spyOn keeps the assignment type-safe (no `as unknown as typeof fetch` cast).
    const fetchMock = jest
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(new Response(null, { status: 200 }));
    try {
      const service = makeService([
        // private literal → rejected
        rule({ actions: [{ type: 'webhook', url: 'https://192.168.1.10/hook' }] }),
        // IPv4-mapped-IPv6 cloud-metadata literal → rejected (bypass closed)
        rule({ id: 'r2', actions: [{ type: 'webhook', url: 'https://[::ffff:169.254.169.254]/x' }] }),
        // bare internal service name → unresolvable offline / internal IP → rejected
        rule({ id: 'r3', actions: [{ type: 'webhook', url: 'https://realtime/hook' }] }),
        // public IP literal → accepted (no DNS needed, works offline)
        rule({ id: 'r4', actions: [{ type: 'webhook', url: 'https://93.184.216.34/x' }] }),
      ]);
      await service.runForWrite(event(), jest.fn(async () => undefined), jest.fn(async () => undefined));
      expect(fetchMock).toHaveBeenCalledTimes(1);
      // The data plane passes the raw URL string as fetch's first arg, so assert
      // it directly — no String() coercion (which Sonar S6551 flags as risking
      // '[object Object]' for the RequestInfo | URL union).
      expect(fetchMock.mock.calls[0][0]).toBe('https://93.184.216.34/x');
    } finally {
      fetchMock.mockRestore();
    }
  });
});

describe('isPrivateAddress (SSRF classifier)', () => {
  it('blocks loopback / private / link-local / CGNAT and both IPv4-mapped-IPv6 encodings', () => {
    for (const a of [
      '127.0.0.1', '10.0.0.5', '192.168.1.10', '172.16.0.1', '169.254.169.254',
      '100.64.0.1', '0.0.0.0',
      '::1', '::', 'fe80::1', 'fc00::1', 'fd12:3456::1', 'ff02::1',
      '::ffff:169.254.169.254', '::ffff:a9fe:a9fe', // dotted + hex IPv4-mapped metadata
      'not-an-ip',
    ]) {
      expect(isPrivateAddress(a)).toBe(true);
    }
  });

  it('allows public IPv4 and global-unicast IPv6', () => {
    for (const a of ['93.184.216.34', '1.1.1.1', '8.8.8.8', '2606:4700:4700::1111']) {
      expect(isPrivateAddress(a)).toBe(false);
    }
  });
});
