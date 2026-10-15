import { afterAll, beforeAll, describe, expect, it } from '@jest/globals';
import { Controller, Get, Res } from '@nestjs/common';
import type { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import type { Response } from 'express';
import { LoggerModule } from 'nestjs-pino';
import { Writable } from 'node:stream';
import { createPinoHttpOptions } from './logger';

/** SessionController answers with two cookies, the way a login sets them. */
@Controller('session')
class SessionController {
  @Get()
  open(@Res({ passthrough: true }) res: Response): { ok: boolean } {
    res.setHeader('set-cookie', [
      'sid=fake-session-cookie; HttpOnly',
      'refresh=fake-refresh-cookie; HttpOnly',
    ]);
    return { ok: true };
  }
}

type LogLine = {
  msg?: string;
  req?: { headers?: Record<string, unknown> };
  res?: { headers?: Record<string, unknown> };
};

/**
 * completedLine waits for pino-http's "request completed" line, which it writes
 * on the response's finish event, after the client may already hold the body.
 * ponytail: bounded at 50 event-loop turns — a slower writer reads as a missing
 * line, so the test fails rather than passes; raise the bound if CI is that slow.
 */
async function completedLine(lines: string[]): Promise<string> {
  for (let turn = 0; turn < 50; turn++) {
    const hit = lines.find((line) => line.includes('"msg":"request completed"'));
    if (hit) return hit;
    await new Promise((resolve) => setImmediate(resolve));
  }
  throw new Error('pino-http wrote no "request completed" line');
}

describe('createPinoHttpOptions — credentials never reach the request log', () => {
  const credentials: Record<string, string> = {
    authorization: 'Bearer fake-bearer-token',
    apikey: 'fake-apikey-value',
    'x-baas-api-key': 'fake-baas-api-key',
    'x-service-token': 'fake-service-token',
    'x-service-auth': 'v1.0.fake-service-signature',
    cookie: 'sid=fake-request-cookie',
  };
  const cookieValues = ['fake-session-cookie', 'fake-refresh-cookie'];
  const lines: string[] = [];
  let app: INestApplication;
  let completed: LogLine;

  beforeAll(async () => {
    const sink = new Writable({
      write(chunk: Buffer, _encoding, done) {
        lines.push(chunk.toString());
        done();
      },
    });
    const mod = await Test.createTestingModule({
      imports: [LoggerModule.forRoot({ pinoHttp: [createPinoHttpOptions('redact-spec'), sink] })],
      controllers: [SessionController],
    }).compile();
    app = mod.createNestApplication({ logger: false });
    await app.listen(0);
    const base = (await app.getUrl()).replace('[::1]', 'localhost');
    const res = await fetch(`${base}/session`, {
      headers: { ...credentials, 'x-request-id': 'req-kept-1041' },
    });
    await res.arrayBuffer();
    completed = JSON.parse(await completedLine(lines)) as LogLine;
  });

  afterAll(async () => {
    await app.close();
  });

  it.each(Object.keys(credentials))('req.headers[%s] is [REDACTED]', (name) => {
    expect(completed.req?.headers?.[name]).toBe('[REDACTED]');
  });

  it('res.headers[set-cookie] is [REDACTED]', () => {
    expect(completed.res?.headers?.['set-cookie']).toBe('[REDACTED]');
  });

  it('no credential or cookie value appears in any line the request produced', () => {
    const everything = lines.join('');
    for (const value of [...Object.values(credentials), ...cookieValues]) {
      expect(everything).not.toContain(value);
    }
  });

  it('a harmless header survives: x-request-id keeps its value', () => {
    expect(completed.req?.headers?.['x-request-id']).toBe('req-kept-1041');
  });
});
