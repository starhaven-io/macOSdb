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
      namespaces: {
        news: false,
        video: false,
        image: false,
      },
      chunks: {
        macos: (item) => {
          if (/\/macos\//.test(item.url)) return item;
        },
        xcode: (item) => {
          if (/\/xcode\//.test(item.url)) return item;
        },
      },
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
