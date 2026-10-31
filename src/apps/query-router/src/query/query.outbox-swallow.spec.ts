// The write path swallows a failed outbox emission: the caller gets its result, the event
// is lost, and only a WARN says so. Pinned here because ENGINE_TLS_ENGINES=pg-clients turns
// a wrong CA into exactly this failure (docs/adr/0032-g5-node-pg-clients-verify-full.md W2);
// the live half is scripts/verify/m264-pg-clients-tls.sh.
// `@types/jest` is not installed, so the globals are imported explicitly.
import { describe, expect, it, jest } from '@jest/globals';
import type { ConfigService } from '@nestjs/config';
import type { HttpService } from '@nestjs/axios';
import { Logger } from '@nestjs/common';
import { of } from 'rxjs';
import type { VerifiedRequestIdentity } from '@mini-baas/common';
import { QueryService } from './query.service';
import { ExecuteQueryDto } from './dto/query.dto';
import type { OutboxService } from './outbox.service';
import type { RustDataPlaneProxy } from '../proxy/rust-data-plane.proxy';
import type { RealtimePublisherService } from './realtime-publisher.service';
import type { AutomationsService } from './automations.service';
import type { TxnOpDto } from './dto/txn.dto';

const config = {
  getOrThrow: () => 'http://adapter-registry:3020',
  get: (_key: string, def?: unknown) => def,
} as unknown as ConfigService;

// An api-key identity: decideByApiKeyScope answers without the permission engine.
const identity: VerifiedRequestIdentity = {
  tenantId: 't-1',
  projectId: 't-1',
  appId: 'api-key',
  userId: 'api-key:k-1',
  role: 'authenticated',
  roleNames: ['authenticated'],
  scopes: ['read', 'write'],
  authMethod: 'kong-hmac',
};

const certError = new Error('unable to verify the first certificate');
const row = { id: 'r-1', title: 'kept' };

function build() {
  const http = {
    get: jest.fn(() =>
      of({
        data: { engine: 'postgresql', connection_string: 'postgres://example/db', revision: 1 },
      }),
    ),
  };
  const rustProxy = {
    shouldForward: jest.fn(() => true),
    execute: jest.fn(async () => ({ rows: [row], rowCount: 1 })),
    beginTransaction: jest.fn(async () => 'tx-1'),
    executeInTransaction: jest.fn(async () => ({ rows: [], rowCount: 1 })),
    commitTransaction: jest.fn(async () => undefined),
  };
  const emitForQuery = jest.fn(async () => {
    throw certError;
  });
  const service = new QueryService(
    config,
    http as unknown as HttpService,
    { emitForQuery } as unknown as OutboxService,
    rustProxy as unknown as RustDataPlaneProxy,
    { publishRowChanged: jest.fn(async () => undefined) } as unknown as RealtimePublisherService,
    { runForWrite: jest.fn(async () => undefined) } as unknown as AutomationsService,
  );
  const warn = jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
  return { service, emitForQuery, warn };
}

// The txn path emits fire-and-forget, so its catch runs after executeTransaction resolves.
const settle = () => new Promise((resolve) => setImmediate(resolve));

describe('QueryService swallows a failed outbox emission (ADR 0032 W2)', () => {
  it('a write still returns its result and WARNs "outbox emission failed"', async () => {
    const { service, emitForQuery, warn } = build();
    const result = await service.executeQuery(
      'db-1',
      'notes',
      'api-key:k-1',
      Object.assign(new ExecuteQueryDto(), { op: 'insert', data: row }),
      { identity },
    );
    expect(result).toMatchObject({ rows: [row], rowCount: 1 });
    expect(emitForQuery).toHaveBeenCalledTimes(1);
    expect(warn).toHaveBeenCalledWith(
      expect.stringContaining(
        `outbox emission failed for postgresql.notes.insert: ${certError.message}`,
      ),
    );
    warn.mockRestore();
  });

  it('a transaction still commits and WARNs "txn outbox emit … failed" per op', async () => {
    const { service, emitForQuery, warn } = build();
    const ops = [
      { op: 'insert', resource: 'notes', data: row },
      { op: 'update', resource: 'notes', data: row, filter: { id: 'r-1' } },
    ] as TxnOpDto[];
    const result = await service.executeTransaction('db-1', 'api-key:k-1', ops, { identity });
    await settle();
    expect(result).toMatchObject({ results: [{ rowCount: 1 }, { rowCount: 1 }] });
    expect(emitForQuery).toHaveBeenCalledTimes(2);
    for (const op of ['insert', 'update']) {
      expect(warn).toHaveBeenCalledWith(
        `txn outbox emit for postgresql.notes.${op} failed: ${certError.message}`,
      );
    }
    warn.mockRestore();
  });
});
