// @ts-check
import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';
import sitemap from '@astrojs/sitemap';
import pagefind from 'astro-pagefind';
import { codecovVitePlugin } from '@codecov/vite-plugin';

// https://astro.build/config
export default defineConfig({
  site: 'https://macosdb.com',
  adapter: cloudflare({
    prerenderEnvironment: 'node',
    imageService: 'passthrough',
  }),
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
  vite: {
    optimizeDeps: {
      exclude: ['astro'],
    },
    plugins: [
      codecovVitePlugin({
        enableBundleAnalysis: process.env.CODECOV_TOKEN !== undefined,
        bundleName: 'macosdb-site',
        uploadToken: process.env.CODECOV_TOKEN,
        gitService: 'github',
      }),
    ],
  },
  experimental: {
    svgo: true,
    clientPrerender: true,
    queuedRendering: {
      enabled: true,
    },
  },
});
