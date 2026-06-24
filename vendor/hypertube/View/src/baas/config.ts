export type BaasConfig = {
  url: string;
  anonKey: string;
  apiKey: string;
  tenantId: string;
  mongoDbId: string;
  dynamoDbId: string;
  realtimeToken: string;
};

/** readConfig merges the runtime window.__BAAS__ over build-time VITE_BAAS_* env. */
export function readConfig(): BaasConfig {
  const w = (typeof window !== 'undefined' ? window.__BAAS__ : undefined) ?? {};
  const e = import.meta.env;
  return {
    url: w.url ?? e.VITE_BAAS_URL ?? '',
    anonKey: w.anonKey ?? e.VITE_BAAS_KONG_KEY ?? '',
    apiKey: w.apiKey ?? e.VITE_BAAS_API_KEY ?? '',
    tenantId: w.tenantId ?? e.VITE_BAAS_TENANT_ID ?? '',
    mongoDbId: w.mongoDbId ?? e.VITE_BAAS_MONGO_DB_ID ?? '',
    dynamoDbId: w.dynamoDbId ?? e.VITE_BAAS_DYNAMO_DB_ID ?? '',
    realtimeToken: w.realtimeToken ?? e.VITE_BAAS_REALTIME_TOKEN ?? '',
  };
}
