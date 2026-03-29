// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import pagefind from 'astro-pagefind';

// https://astro.build/config
export default defineConfig({
  site: 'https://macosdb.com',
  integrations: [
    sitemap({
      filter: (page) => !page.includes('/api/'),
    }),
    pagefind(),
  ],
  prefetch: {
    prefetchAll: true,
    defaultStrategy: 'hover',
  },
  experimental: {
    svgo: true,
  },
});
