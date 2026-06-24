// config.ts — reads the runtime BaaS config injected by public/baas-config.js
// (window.__BAAS__) before the app module loads. No import.meta.env — the
// provisioning agent rewrites baas-config.js, and serve.mjs rewrites `url` to the
// SPA's own origin so all gateway calls are same-origin.

import { isRecord, asString } from './guards';

/** BaasConfig is the resolved runtime configuration shape. */
export type BaasConfig = {
  url: string;
  anonKey: string;
  apiKey: string;
  tenantId: string;
  pgDbId: string;
  mongoDbId: string;
  realtimeToken: string;
};

/** readWindowConfig narrows window.__BAAS__ to a partial BaasConfig (never throws). */
function readWindowConfig(): Partial<BaasConfig> {
  const raw: unknown = typeof window !== 'undefined' ? (window as { __BAAS__?: unknown }).__BAAS__ : undefined;
  if (!isRecord(raw)) return {};
  return {
    url: asString(raw.url),
    anonKey: asString(raw.anonKey),
    apiKey: asString(raw.apiKey),
    tenantId: asString(raw.tenantId, 'nimbus'),
    pgDbId: asString(raw.pgDbId),
    mongoDbId: asString(raw.mongoDbId),
    realtimeToken: asString(raw.realtimeToken),
  };
}

/** getConfig resolves the runtime config with safe defaults for missing keys. */
export function getConfig(): BaasConfig {
  const c = readWindowConfig();
  return {
    url: c.url ?? '',
    anonKey: c.anonKey ?? '',
    apiKey: c.apiKey ?? '',
    tenantId: c.tenantId ?? 'nimbus',
    pgDbId: c.pgDbId ?? '',
    mongoDbId: c.mongoDbId ?? '',
    realtimeToken: c.realtimeToken ?? '',
  };
}

const REQUIRED = ['url', 'anonKey', 'apiKey', 'pgDbId'] as const;

/** assertConfigured throws a clear error when a required field is missing,
 * pointing the developer at the provisioning step that fills baas-config.js. */
export function assertConfigured(config: BaasConfig): void {
  const missing = REQUIRED.filter((k) => !config[k]);
  if (missing.length) {
    throw new Error(
      `Nimbus: BaaS config missing [${missing.join(', ')}] — the provisioning agent must ` +
        'regenerate public/baas-config.js with real tenant values.',
    );
  }
}
