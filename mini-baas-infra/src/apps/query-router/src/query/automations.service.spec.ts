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
import { AutomationsService, evaluateCondition, type AutomationWriteEvent } from './automations.service';
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
  } as AutomationRuleDto;
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
    const realFetch = globalThis.fetch;
    const fetchMock = jest.fn(async (_url: unknown, _init?: unknown) => ({ ok: true, status: 200 }));
    globalThis.fetch = fetchMock as unknown as typeof fetch;
    try {
      const service = makeService([
        rule({ actions: [{ type: 'webhook', url: 'https://192.168.1.10/hook' }] }),
        rule({ id: 'r2', actions: [{ type: 'webhook', url: 'https://realtime/hook' }] }),
        rule({ id: 'r3', actions: [{ type: 'webhook', url: 'https://hooks.example.com/x' }] }),
      ]);
      await service.runForWrite(event(), jest.fn(async () => undefined), jest.fn(async () => undefined));
      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(String(fetchMock.mock.calls[0][0])).toBe('https://hooks.example.com/x');
    } finally {
      globalThis.fetch = realFetch;
    }
  });
});
