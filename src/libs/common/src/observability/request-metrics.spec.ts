import { afterAll, beforeAll, describe, expect, it, jest } from '@jest/globals';
import {
  CanActivate,
  Controller,
  ForbiddenException,
  Get,
  HttpException,
  Injectable,
  MiddlewareConsumer,
  Module,
  NestMiddleware,
  NestModule,
  UseGuards,
} from '@nestjs/common';
import type { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import type { NextFunction, Request, Response } from 'express';
import { register } from 'prom-client';
import { ObservabilityModule } from './observability.module';

/** RejectKeyMiddleware answers 401 itself, the way ApiKeyMiddleware does. */
@Injectable()
class RejectKeyMiddleware implements NestMiddleware {
  use(req: Request, res: Response, next: NextFunction): void {
    if (req.headers['x-baas-api-key'] === 'bad') {
      res.status(401).json({ error: 'invalid_api_key' });
      return;
    }
    next();
  }
}

/** DenyGuard refuses every request, the way AuthGuard does without identity. */
@Injectable()
class DenyGuard implements CanActivate {
  canActivate(): boolean {
    throw new HttpException('Missing verified identity', 401);
  }
}

@Controller('items')
class ItemsController {
  @Get('open/:id')
  open(): { ok: boolean } {
    return { ok: true };
  }

  @Get('guarded/:id')
  @UseGuards(DenyGuard)
  guarded(): { ok: boolean } {
    return { ok: true };
  }

  @Get('forbidden/:id')
  forbidden(): never {
    throw new ForbiddenException('not yours');
  }

  @Get('limited/:id')
  limited(): never {
    throw new HttpException('slow down', 429);
  }
}

@Module({
  imports: [ObservabilityModule],
  controllers: [ItemsController],
  providers: [RejectKeyMiddleware],
})
class TestAppModule implements NestModule {
  configure(consumer: MiddlewareConsumer): void {
    consumer.apply(RejectKeyMiddleware).forRoutes('*');
  }
}

/** count reads mini_baas_http_requests_total for one route/status pair. */
async function count(route: string, status: string): Promise<number> {
  const metric = register.getSingleMetric('mini_baas_http_requests_total');
  const values = (await metric?.get())?.values ?? [];
  const hit = values.find((v) => v.labels.route === route && v.labels.status_code === status);
  return hit?.value ?? 0;
}

describe('request metrics — every response is counted, rejections included', () => {
  let app: INestApplication;
  let base: string;
  const lines: string[] = [];

  beforeAll(async () => {
    process.env['OTEL_SERVICE_NAME'] = 'metrics-spec';
    const mod = await Test.createTestingModule({ imports: [TestAppModule] }).compile();
    app = mod.createNestApplication({ logger: false });
    await app.listen(0);
    base = (await app.getUrl()).replace('[::1]', 'localhost');
    jest.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
      lines.push(String(chunk));
      return true;
    });
  });

  afterAll(async () => {
    jest.restoreAllMocks();
    await app.close();
  });

  /** call requests a path and returns the http_request log line it produced. */
  async function call(path: string, headers: Record<string, string> = {}) {
    const res = await fetch(`${base}${path}`, { headers });
    await res.arrayBuffer();
    await new Promise((r) => setImmediate(r));
    const line = lines.reverse().find((l) => l.includes(`"status_code":${res.status}`));
    lines.length = 0;
    return {
      status: res.status,
      log: line ? (JSON.parse(line) as Record<string, unknown>) : undefined,
    };
  }

  type Case = {
    name: string;
    path: string;
    headers?: Record<string, string>;
    status: number;
    route: string;
    event?: string;
  };
  const cases: Case[] = [
    {
      name: 'a middleware 401',
      path: '/items/open/1',
      headers: { 'x-baas-api-key': 'bad' },
      status: 401,
      route: 'unrouted',
      event: 'auth_failure',
    },
    {
      name: 'a guard 401',
      path: '/items/guarded/1',
      status: 401,
      route: '/items/guarded/:id',
      event: 'auth_failure',
    },
    {
      name: 'a handler 403',
      path: '/items/forbidden/1',
      status: 403,
      route: '/items/forbidden/:id',
      event: 'access_denied',
    },
    {
      name: 'a 429',
      path: '/items/limited/1',
      status: 429,
      route: '/items/limited/:id',
      event: 'rate_limited',
    },
    { name: 'a success', path: '/items/open/1', status: 200, route: '/items/open/:id' },
  ];

  it.each(cases)('$name is counted and logged', async ({ path, headers, status, route, event }) => {
    const before = await count(route, String(status));
    const { status: got, log } = await call(path, headers);
    expect(got).toBe(status);
    expect(await count(route, String(status))).toBe(before + 1);
    expect(log).toMatchObject({ service: 'metrics-spec', route, status_code: status });
    expect(log?.['event_type']).toBe(event);
  });

  it('an unmatched path is counted under one route label, never its raw path', async () => {
    const raw = `/scan-${Date.now()}`;
    const before = await count('unrouted', '404');
    const { status, log } = await call(raw);
    expect(status).toBe(404);
    expect(await count('unrouted', '404')).toBe(before + 1);
    expect(await count(raw, '404')).toBe(0);
    expect(log?.['route']).toBe('unrouted');
  });
});
