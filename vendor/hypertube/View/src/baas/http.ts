import type { BaasConfig } from './config.ts';
import { loadSession } from './session.ts';

export type HttpError = { status: number; message: string };

/** isHttpError narrows an unknown thrown value to the HttpError shape. */
export function isHttpError(e: unknown): e is HttpError {
  return typeof e === 'object' && e !== null && 'status' in e && 'message' in e;
}

/** baseHeaders builds the apikey + api-key + bearer header set for a request. */
export function baseHeaders(cfg: BaasConfig, withBearer = true): Record<string, string> {
  const h: Record<string, string> = {
    'Content-Type': 'application/json',
    apikey: cfg.anonKey,
    'X-Baas-Api-Key': cfg.apiKey,
  };
  const session = withBearer ? loadSession() : null;
  if (session) h.Authorization = `Bearer ${session.accessToken}`;
  return h;
}

/** requestJson issues a fetch and parses JSON, throwing HttpError on non-2xx. */
export async function requestJson<T>(path: string, init: RequestInit): Promise<T> {
  const res = await fetch(path, init);
  const text = await res.text();
  const body = text ? safeParse(text) : null;
  if (!res.ok) {
    throw { status: res.status, message: errorMessage(body, res.statusText) } satisfies HttpError;
  }
  return body as T;
}

/** safeParse parses JSON text, falling back to the raw string on failure. */
function safeParse(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

/** errorMessage extracts a human message from a parsed error body. */
function errorMessage(body: unknown, fallback: string): string {
  if (typeof body === 'string' && body) return body;
  if (typeof body === 'object' && body !== null) {
    const o = body as Record<string, unknown>;
    const m = o.error_description ?? o.message ?? o.error ?? o.msg;
    if (typeof m === 'string') return m;
  }
  return fallback || 'request failed';
}
