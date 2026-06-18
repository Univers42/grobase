import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

function buildCsp(dev = false, upgradeInsecureRequests = false): string {
  return [
    "default-src 'self'",
    "base-uri 'self'",
    "object-src 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    `script-src 'self' 'unsafe-inline'${dev ? " 'unsafe-eval'" : ''} https://accounts.google.com`,
    "style-src 'self' 'unsafe-inline'",
    "font-src 'self' data:",
    "img-src 'self' data: blob: https://images.unsplash.com",
    dev
      ? "connect-src 'self' http://localhost:* http://127.0.0.1:* ws: wss: https://accounts.google.com"
      : "connect-src 'self' https://vite-gourmand.fr https://www.vite-gourmand.fr https://accounts.google.com",
    "frame-src 'self' https://accounts.google.com",
    ...(upgradeInsecureRequests ? ['upgrade-insecure-requests'] : []),
  ].join('; ');
}

const commonSecurityHeaders = {
  'Cross-Origin-Opener-Policy': 'same-origin-allow-popups',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
};

const devSecurityHeaders = {
  ...commonSecurityHeaders,
  'Content-Security-Policy': buildCsp(true),
};

const previewSecurityHeaders = {
  ...commonSecurityHeaders,
  'Content-Security-Policy': buildCsp(false),
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains; preload',
};

// https://vite.dev/config/
export default defineConfig({
  plugins: [tailwindcss(), react()],
  server: {
    port: 5173,
    strictPort: true,
    headers: devSecurityHeaders,
    proxy: {
      '/auth': {
        target: 'http://localhost:3000',
        changeOrigin: true,
      },
      '/api': {
        target: 'http://localhost:3000',
        changeOrigin: true,
      },
    },
  },
  preview: {
    headers: previewSecurityHeaders,
  },
  build: {
    rollupOptions: {
      output: {
        manualChunks: {
          react: ['react', 'react-dom', 'react-router-dom'],
          ui: [
            '@radix-ui/react-slot',
            'class-variance-authority',
            'clsx',
            'lucide-react',
            'tailwind-merge',
          ],
        },
      },
    },
  },
});
