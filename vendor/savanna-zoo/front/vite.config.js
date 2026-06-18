import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'path';

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': resolve(__dirname, 'src'),
    },
  },
  server: {
    port: 5173,
    proxy: {
      // Proxy /rest/v1 and /auth/v1 through Kong gateway
      '/rest': {
        target: process.env.VITE_BAAS_ENDPOINT || 'http://localhost:8001',
        changeOrigin: true,
      },
      '/auth': {
        target: process.env.VITE_BAAS_ENDPOINT || 'http://localhost:8001',
        changeOrigin: true,
      },
      '/storage': {
        target: process.env.VITE_BAAS_ENDPOINT || 'http://localhost:8001',
        changeOrigin: true,
      },
    },
  },
});
