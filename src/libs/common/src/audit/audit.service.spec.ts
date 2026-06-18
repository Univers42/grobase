// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { describe, expect, it } from '@jest/globals';
import { AuditService } from './audit.service';

describe('AuditService', () => {
  it('reuses the registered prom-client counter across instances (idempotent registration)', () => {
    // The first construction registers the failure counter; the second must hit
    // the `existing instanceof Counter` reuse branch in auditFailureCounter()
    // rather than re-registering (which prom-client would reject).
    const first = new AuditService();
    const second = new AuditService();
    expect(first).toBeInstanceOf(AuditService);
    expect(second).toBeInstanceOf(AuditService);
  });

  it('record() is a no-op (resolves, never throws) when no pool is configured', async () => {
    // onModuleInit is not called, so no pool exists — record() returns early and
    // must never surface an error to the mutating request path.
    const svc = new AuditService();
    await expect(
      svc.record({ requestId: 'req-1', action: 'create', resource: 'widget' }),
    ).resolves.toBeUndefined();
  });

  it('onModuleDestroy() is safe to call without an initialized pool', async () => {
    const svc = new AuditService();
    await expect(svc.onModuleDestroy()).resolves.toBeUndefined();
  });
});
