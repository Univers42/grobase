interface ImportMetaEnv {
  readonly BASE_URL: string;
  readonly DEV: boolean;
  readonly MODE: string;
  readonly PROD: boolean;
  readonly SSR: boolean;
  readonly VITE_API_URL?: string;
  readonly VITE_PUBLIC_SITE_URL?: string;
  readonly VITE_BAAS_URL?: string;
  readonly VITE_BAAS_KONG_KEY?: string;
  readonly VITE_BAAS_API_KEY?: string;
  readonly VITE_BAAS_TENANT_ID?: string;
  readonly VITE_BAAS_PG_DB_ID?: string;
  readonly VITE_BAAS_MONGO_DB_ID?: string;
  readonly VITE_BAAS_REALTIME_TOKEN?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

declare module '*.css';
declare module '*.svg';
declare module '*.png';
declare module '*.jpg';
declare module '*.jpeg';
declare module '*.webp';