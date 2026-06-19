import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

/** buildCsp renders the strict, inline-free CSP (no script/style 'unsafe-inline'). */
function buildCsp(dev = false): string {
  return [
    "default-src 'self'",
    "base-uri 'self'",
    "object-src 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    `script-src 'self'${dev ? " 'unsafe-inline' 'unsafe-eval'" : ''}`,
    "style-src 'self' 'unsafe-inline'",
    "font-src 'self' data:",
    "img-src 'self' data: blob: https:",
    'media-src \'self\' blob:',
    dev ? "connect-src 'self' http://localhost:* http://127.0.0.1:* ws: wss:" : "connect-src 'self' ws: wss:",
    "frame-src 'none'",
  ].join('; ');
}

const securityHeaders = {
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
};

const kong = process.env.VITE_BAAS_URL ?? 'http://127.0.0.1:8002';
const proxy = Object.fromEntries(
  ['/auth', '/query', '/storage', '/realtime', '/rest', '/functions', '/media', '/search', '/api'].map((p) => [
    p,
    { target: kong, changeOrigin: true, ws: p === '/realtime' },
  ]),
);

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: true,
    headers: { ...securityHeaders, 'Content-Security-Policy': buildCsp(true) },
    proxy,
  },
  preview: {
    headers: { ...securityHeaders, 'Content-Security-Policy': buildCsp(false) },
  },
  build: {
    rollupOptions: {
      output: { manualChunks: { react: ['react', 'react-dom', 'react-router-dom'] } },
    },
  },
});
