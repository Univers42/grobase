import { describe, expect, it } from '@jest/globals';
import { UnauthorizedException } from '@nestjs/common';
import type { ExecutionContext } from '@nestjs/common';
import type { ConfigService } from '@nestjs/config';
import { register } from 'prom-client';
import { ServiceTokenGuard } from './service-token.guard';

/** guardWith builds the guard over a config holding only the given values. */
function guardWith(values: Record<string, string>): ServiceTokenGuard {
  const config = { get: (k: string) => values[k] } as unknown as ConfigService;
  return new ServiceTokenGuard(config);
}

/** ctx wraps a request carrying an X-Service-Token and the tenant it acts for. */
function ctx(token: string) {
  const req = { headers: { 'x-service-token': token, 'x-tenant-id': 't-rotate' } } as Record<
    string,
    unknown
  >;
  const context = {
    switchToHttp: () => ({ getRequest: () => req }),
  } as unknown as ExecutionContext;
  return { req, context };
}

/** previousAccepted reads the rotation-window counter. */
async function previousAccepted(): Promise<number> {
  const metric = register.getSingleMetric('baas_service_token_previous_accepted_total');
  return (await metric?.get())?.values[0]?.value ?? 0;
}

describe('ServiceTokenGuard — rotation window (G-Rotate)', () => {
  const current = 'tok-current-0123456789';
  const previous = 'tok-previous-0123456789';

  it('accepts the current token', async () => {
    const { req, context } = ctx(current);
    await expect(
      guardWith({ ADAPTER_REGISTRY_SERVICE_TOKEN: current }).canActivate(context),
    ).resolves.toBe(true);
    expect(req['identity']).toBeDefined();
  });

  it('accepts the previous token while ADAPTER_REGISTRY_SERVICE_TOKEN_PREV holds it, and counts it', async () => {
    const before = await previousAccepted();
    const guard = guardWith({
      ADAPTER_REGISTRY_SERVICE_TOKEN: current,
      ADAPTER_REGISTRY_SERVICE_TOKEN_PREV: previous,
    });
    await expect(guard.canActivate(ctx(previous).context)).resolves.toBe(true);
    expect(await previousAccepted()).toBe(before + 1);
  });

  it('does not count the current token as a previous one', async () => {
    const before = await previousAccepted();
    const guard = guardWith({
      ADAPTER_REGISTRY_SERVICE_TOKEN: current,
      ADAPTER_REGISTRY_SERVICE_TOKEN_PREV: previous,
    });
    await guard.canActivate(ctx(current).context);
    expect(await previousAccepted()).toBe(before);
  });

  it.each([
    ['no window open', { ADAPTER_REGISTRY_SERVICE_TOKEN: current }, previous],
    [
      'an unrelated token during the window',
      { ADAPTER_REGISTRY_SERVICE_TOKEN: current, ADAPTER_REGISTRY_SERVICE_TOKEN_PREV: previous },
      'tok-other-0123456789',
    ],
    [
      'an empty token against an empty PREV',
      { ADAPTER_REGISTRY_SERVICE_TOKEN: current, ADAPTER_REGISTRY_SERVICE_TOKEN_PREV: '' },
      '',
    ],
  ])('refuses %s', async (_name, values, token) => {
    await expect(guardWith(values).canActivate(ctx(token).context)).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
  });
});
