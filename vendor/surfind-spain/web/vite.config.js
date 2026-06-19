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
    port: 5183,
    proxy: {
      '/rest': { target: process.env.VITE_BAAS_ENDPOINT || 'http://localhost:8002', changeOrigin: true },
      '/auth': { target: process.env.VITE_BAAS_ENDPOINT || 'http://localhost:8002', changeOrigin: true },
      '/realtime': { target: process.env.VITE_BAAS_ENDPOINT || 'http://localhost:8002', changeOrigin: true, ws: true },
      '/storage': { target: process.env.VITE_BAAS_ENDPOINT || 'http://localhost:8002', changeOrigin: true },
    },
  },
});
