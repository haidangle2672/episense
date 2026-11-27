import { defineConfig } from 'astro/config';
import react from '@astrojs/react';

export default defineConfig({
  site: 'https://episense.io.vn',
  integrations: [react()],
  vite: {
    server: {
      proxy: {
        // Chỉ có tác dụng khi chạy dev; bản build thật gọi cùng nguồn qua Caddy
        '/api': { target: 'https://episense.io.vn', changeOrigin: true },
      },
    },
  },
});