import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

const KONG = process.env.VITE_BAAS_URL ?? 'http://127.0.0.1:8002';

function buildCsp(dev: boolean): string {
  return [
    "default-src 'self'",
    "base-uri 'self'",
    "object-src 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    `script-src 'self'${dev ? " 'unsafe-inline' 'unsafe-eval'" : ''}`,
    "style-src 'self' 'unsafe-inline'",
    "font-src 'self' data:",
    "img-src 'self' data: blob:",
    "media-src 'self'",
    dev
      ? "connect-src 'self' http://localhost:* http://127.0.0.1:* ws: wss:"
      : "connect-src 'self' ws: wss:",
  ].join('; ');
}

const commonHeaders = {
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
};

const proxyTargets = ['/auth', '/query', '/storage', '/realtime', '/rest', '/functions', '/analytics'];
const proxy = Object.fromEntries(
  proxyTargets.map((p) => [p, { target: KONG, changeOrigin: true, ws: p === '/realtime' }]),
);

export default defineConfig({
  plugins: [react()],
  server: {
    port: 8124,
    strictPort: true,
    headers: { ...commonHeaders, 'Content-Security-Policy': buildCsp(true) },
    proxy,
  },
  preview: {
    headers: {
      ...commonHeaders,
      'Content-Security-Policy': buildCsp(false),
      'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
    },
  },
  build: {
    rollupOptions: {
      output: {
        manualChunks: {
          react: ['react', 'react-dom', 'react-router-dom'],
          ui: ['@radix-ui/react-dialog', '@radix-ui/react-dropdown-menu', '@radix-ui/react-toast', 'lucide-react', 'clsx'],
        },
      },
    },
  },
});
