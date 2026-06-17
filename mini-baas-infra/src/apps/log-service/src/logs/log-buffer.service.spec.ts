// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { describe, expect, it } from '@jest/globals';
import { LogBufferService } from './log-buffer.service';

describe('LogBufferService', () => {
  it('buffers an entry, stamps createdAt, and reports the count/list', () => {
    // Constructing the service runs the field initializers (incl. the default
    // loki URL). add()/list()/getCount() never touch the network here: the flush
    // timer is not started (onModuleInit is not called) and the queue stays well
    // under the batch size, so flush() is never triggered.
    const svc = new LogBufferService();
    const buffered = svc.add({ level: 'info', source: 'unit-test', message: 'hello' });
    expect(buffered.createdAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(svc.getCount()).toBe(1);
    expect(svc.list()).toEqual([buffered]);
  });

  it('list() honours the limit argument while getCount() reflects the full buffer', () => {
    const svc = new LogBufferService();
    for (let i = 0; i < 5; i++) {
      svc.add({ level: 'debug', source: 's', message: `m${i}` });
    }
    expect(svc.list(2)).toHaveLength(2);
    expect(svc.getCount()).toBe(5);
  });
});
