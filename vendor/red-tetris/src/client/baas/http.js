// Thin fetch wrapper for the Grobase gateway (same-origin via grobase/serve.mjs).
import config from './config.js';
import { loadSession } from './session.js';

/** baseHeaders builds the apikey + app-key + optional Bearer header set. */
export function baseHeaders(withBearer = true) {
  const h = {
    'Content-Type': 'application/json',
    apikey: config.anonKey,
    'X-Baas-Api-Key': config.apiKey,
  };
  const session = withBearer ? loadSession() : null;
  if (session) h.Authorization = `Bearer ${session.accessToken}`;
  return h;
}

/** requestJson issues a fetch and parses JSON, throwing {status,message} on non-2xx. */
export async function requestJson(path, init) {
  const res = await fetch(path, init);
  const text = await res.text();
  const body = text ? safeParse(text) : null;
  if (!res.ok) throw { status: res.status, message: errorMessage(body, res.statusText) };
  return body;
}

/** safeParse parses JSON text, falling back to the raw string on failure. */
function safeParse(text) {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

/** errorMessage extracts a human message from a parsed error body. */
function errorMessage(body, fallback) {
  if (typeof body === 'string' && body) return body;
  if (body && typeof body === 'object') {
    const m = body.error_description ?? body.message ?? body.error ?? body.msg;
    if (typeof m === 'string') return m;
  }
  return fallback || 'request failed';
}
