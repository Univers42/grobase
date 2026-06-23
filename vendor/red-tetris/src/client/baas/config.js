// Grobase frontend config — read once from window.__BAAS__ (emitted by
// scripts/seed/red-tetris-tenant.sh into public/baas-config.js, served same-origin
// by grobase/serve.mjs with `url` rewritten to ''). The SPA owns no data; every
// value here is provisioned by the contract + seed.

/** readConfig returns the window.__BAAS__ config with safe defaults. */
export function readConfig() {
  const w = (typeof window !== 'undefined' && window.__BAAS__) || {};
  return {
    url: w.url ?? '',
    anonKey: w.anonKey ?? '',
    apiKey: w.apiKey ?? '',
    tenantId: w.tenantId ?? 'red-tetris',
    pgDbId: w.pgDbId ?? '',
    mongoDbId: w.mongoDbId ?? '',
    redisDbId: w.redisDbId ?? '',
    realtimeToken: w.realtimeToken ?? '',
    storageBucket: w.storageBucket ?? 'avatars',
  };
}

const config = readConfig();
export default config;
