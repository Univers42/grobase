/**
 * API Base Service
 * Centralized fetch wrapper with auth handling
 */

// Use empty string to let Vite proxy or same-origin production hosting handle /api routes.
const API_BASE = getSecureApiBase(import.meta.env.VITE_API_URL || '');
const LEGACY_ACCESS_TOKEN_KEY = 'accessToken';
const LEGACY_REFRESH_TOKEN_KEY = 'refreshToken';
const CSRF_COOKIE_KEY = 'vg_csrf_token';
const CSRF_HEADER_KEY = 'X-CSRF-Token';

let authenticatedSession = false;

function isLocalHttpUrl(url: URL): boolean {
  return url.protocol === 'http:' && ['localhost', '127.0.0.1', '::1'].includes(url.hostname);
}

function getSecureApiBase(apiBase: string): string {
  if (!apiBase || !import.meta.env.PROD) return apiBase;

  const url = new URL(apiBase, 'https://vite-gourmand.invalid');
  if (url.protocol === 'https:' || isLocalHttpUrl(url)) return apiBase;

  throw new Error(`VITE_API_URL must use https:// in production. Received: ${apiBase}`);
}

interface ApiOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  body?: unknown;
  headers?: Record<string, string>;
}

class ApiError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

function clearLegacyTokenStorage(): void {
  try {
    localStorage.removeItem(LEGACY_ACCESS_TOKEN_KEY);
    localStorage.removeItem(LEGACY_REFRESH_TOKEN_KEY);
  } catch {
    // Storage can be unavailable in private/locked-down contexts.
  }
}

function readCookie(name: string): string | null {
  try {
    const cookies = document.cookie.split(';');
    for (const cookie of cookies) {
      const [rawName, ...rawValueParts] = cookie.trim().split('=');
      if (rawName !== name) continue;
      return decodeURIComponent(rawValueParts.join('='));
    }
  } catch {
    // document.cookie can be unavailable in some locked-down contexts.
  }
  return null;
}

function clearReadableCookie(name: string): void {
  try {
    document.cookie = `${name}=; Max-Age=0; Path=/; SameSite=Lax`;
  } catch {
    // document.cookie can be unavailable in some locked-down contexts.
  }
}

function shouldAttachCsrfToken(method: string): boolean {
  return !['GET', 'HEAD', 'OPTIONS'].includes(method.toUpperCase());
}

clearLegacyTokenStorage();

/** Mark that the browser has a cookie-backed authenticated session. */
export function setTokens(_access?: string, _refresh?: string): void {
  clearLegacyTokenStorage();
  authenticatedSession = true;
}

/** Clear auth session markers and legacy browser-readable tokens. */
export function clearTokens(): void {
  authenticatedSession = false;
  clearLegacyTokenStorage();
  clearReadableCookie(CSRF_COOKIE_KEY);
}

/** Check if user is authenticated */
export function isAuthenticated(): boolean {
  return authenticatedSession;
}

/** Make API request with auth handling */
export async function apiRequest<T>(endpoint: string, options: ApiOptions = {}): Promise<T> {
  const { method = 'GET', body, headers = {} } = options;

  const requestHeaders: Record<string, string> = {
    'Content-Type': 'application/json',
    ...headers,
  };

  if (shouldAttachCsrfToken(method) && !requestHeaders[CSRF_HEADER_KEY]) {
    const csrfToken = readCookie(CSRF_COOKIE_KEY);
    if (csrfToken) {
      requestHeaders[CSRF_HEADER_KEY] = csrfToken;
    }
  }

  const response = await fetch(`${API_BASE}${endpoint}`, {
    method,
    headers: requestHeaders,
    body: body ? JSON.stringify(body) : undefined,
    credentials: 'include',
  });

  if (!response.ok) {
    // 401 = token expired or invalid → clear stale credentials
    if (response.status === 401) {
      clearTokens();
    }
    const error = await response.json().catch(() => ({ message: response.statusText }));
    throw new ApiError(response.status, error.message || 'Request failed');
  }

  return response.json();
}

export { ApiError };
