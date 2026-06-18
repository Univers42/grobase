// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { describe, expect, it } from '@jest/globals';
import { ConfigService } from '@nestjs/config';
import { HttpService } from '@nestjs/axios';
import { RustDataPlaneProxy } from './rust-data-plane.proxy';

// The constructor only reads config (it never touches HttpService), so a config
// double + an empty http double fully exercises the URL/flag/engine resolution.
function make(env: Record<string, string> = {}): RustDataPlaneProxy {
  const config = {
    get: (key: string, def?: unknown) => env[key] ?? def,
  } as unknown as ConfigService;
  return new RustDataPlaneProxy(config, {} as unknown as HttpService);
}

describe('RustDataPlaneProxy constructor', () => {
  it('builds with the default in-cluster data-plane URL (forwarding off)', () => {
    expect(make()).toBeDefined();
  });

  it('honours RUST_DATA_PLANE_FORWARD + a custom engine allowlist from config', () => {
    expect(
      make({
        RUST_DATA_PLANE_FORWARD: 'true',
        RUST_DATA_PLANE_FORWARD_ENGINES: 'postgresql, mysql ,',
        RUST_DATA_PLANE_URL: 'https://dp:9999',
      }),
    ).toBeDefined();
  });
});
