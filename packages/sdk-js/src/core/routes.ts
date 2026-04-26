export const routes = {
  auth: {
    token: (grantType: 'password' | 'refresh_token') => `/auth/v1/token?grant_type=${grantType}`,
    logout: '/auth/v1/logout',
    user: '/auth/v1/user',
  },
  query: {
    execute: '/query/v1/execute',
  },
  storage: {
    sign: (bucket: string, key: string) =>
      `/storage/v1/sign/${encodeURIComponent(bucket)}/${encodePath(key)}`,
  },
  analytics: {
    events: '/analytics/v1/events',
  },
  realtime: {
    channel: (channel: string) => `/realtime/v1/ws/${encodePath(channel)}`,
  },
} as const;

function encodePath(value: string): string {
  return value
    .split('/')
    .filter(Boolean)
    .map((part) => encodeURIComponent(part))
    .join('/');
}
