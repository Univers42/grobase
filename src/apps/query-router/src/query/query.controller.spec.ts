// The repo's jest setup does not ship `@types/jest` — import globals explicitly.
import { beforeEach, describe, expect, it, jest } from '@jest/globals';
import 'reflect-metadata';
import { BadRequestException } from '@nestjs/common';
import type { UserContext, VerifiedRequestIdentity } from '@mini-baas/common';
import type { Request } from 'express';
import { QueryController } from './query.controller';
import type { QueryService } from './query.service';
import type { ExecuteQueryDto } from './dto/query.dto';
import type { QueryRequestDto } from './dto/query-request.dto';

const DB = '11111111-1111-4111-8111-111111111111';
const USER = { id: 'user-9' } as UserContext;
const IDENTITY = { tenantId: 'tenant-a', userId: 'user-9' } as VerifiedRequestIdentity;
const REQ = { headers: {}, ip: '10.0.0.1', requestId: 'req-1' } as unknown as Request;

type Call = [string, string, string, ExecuteQueryDto, Record<string, unknown>];

/** controllerWith returns a controller whose service records each executeQuery call. */
function controllerWith(calls: Call[]): QueryController {
  const executeQuery = jest.fn(async (...args: Call) => {
    calls.push(args);
    return { rows: [] };
  });
  return new QueryController({ executeQuery } as unknown as QueryService);
}

/** request builds an execute body for the mount DB and resource `notes`. */
function request(action: string, payload?: Record<string, unknown>): QueryRequestDto {
  return { database_id: DB, action, resource: 'notes', payload } as QueryRequestDto;
}

describe('QueryController POST /execute (OpenAPI queryExecute)', () => {
  let calls: Call[];
  let controller: QueryController;

  beforeEach(() => {
    calls = [];
    controller = controllerWith(calls);
  });

  it('runs a canonical op on the mount and resource named in the body', async () => {
    await controller.executeRequest(USER, IDENTITY, request('list', { limit: 5 }), undefined, REQ);
    const [dbId, table, userId, dto, ctx] = calls[0];
    expect([dbId, table, userId]).toEqual([DB, 'notes', 'user-9']);
    expect(dto.resolveOp()).toBe('list');
    expect(dto.limit).toBe(5);
    expect(ctx).toMatchObject({ identity: IDENTITY, requestId: 'req-1', ip: '10.0.0.1' });
  });

  it('maps a legacy verb through the DTO (select → list) and keeps the filter', async () => {
    await controller.executeRequest(
      USER,
      IDENTITY,
      request('select', { filter: { done: false } }),
      undefined,
      REQ,
    );
    expect(calls[0][3].resolveOp()).toBe('list');
    expect(calls[0][3].filter).toEqual({ done: false });
  });

  it('treats `values` as `data` for a single-row write', async () => {
    await controller.executeRequest(
      USER,
      IDENTITY,
      request('insert', { values: { title: 'a' } }),
      undefined,
      REQ,
    );
    expect(calls[0][3].resolveOp()).toBe('insert');
    expect(calls[0][3].data).toEqual({ title: 'a' });
  });

  it('turns an array of `values` on an insert into a batch of inserts', async () => {
    const values = [{ title: 'a' }, { title: 'b' }];
    await controller.executeRequest(USER, IDENTITY, request('insert', { values }), undefined, REQ);
    const dto = calls[0][3];
    expect(dto.resolveOp()).toBe('batch');
    expect(dto.operations?.map((o) => [o.op, o.data])).toEqual([
      ['insert', { title: 'a' }],
      ['insert', { title: 'b' }],
    ]);
  });

  it('forwards the Idempotency-Key header like the per-table route', async () => {
    await controller.executeRequest(
      USER,
      IDENTITY,
      request('insert', { data: { a: 1 } }),
      'key-1',
      REQ,
    );
    expect(calls[0][3].idempotencyKey).toBe('key-1');
  });

  it.each([
    ['an unknown payload field', request('list', { evil: true })],
    ['`values` beside `data`', request('insert', { values: { a: 1 }, data: { a: 2 } })],
    ['an array of `values` on a non-insert', request('update', { values: [{ a: 1 }] })],
    ['an action that is neither an op nor a legacy verb', request('drop', {})],
    ['a limit above the per-table route maximum', request('list', { limit: 501 })],
  ])('refuses %s with 400 and never executes', async (_why, body) => {
    await expect(
      controller.executeRequest(USER, IDENTITY, body, undefined, REQ),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(calls).toHaveLength(0);
  });
});
