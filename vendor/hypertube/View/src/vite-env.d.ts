/// <reference types="vite/client" />

interface BaasRuntimeConfig {
  url: string;
  anonKey: string;
  apiKey: string;
  tenantId: string;
  mongoDbId: string;
  dynamoDbId: string;
  realtimeToken: string;
}

interface Window {
  __BAAS__?: Partial<BaasRuntimeConfig>;
}

interface ImportMetaEnv {
  readonly VITE_BAAS_URL?: string;
  readonly VITE_BAAS_KONG_KEY?: string;
  readonly VITE_BAAS_API_KEY?: string;
  readonly VITE_BAAS_TENANT_ID?: string;
  readonly VITE_BAAS_MONGO_DB_ID?: string;
  readonly VITE_BAAS_DYNAMO_DB_ID?: string;
  readonly VITE_BAAS_REALTIME_TOKEN?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
