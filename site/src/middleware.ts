import { defineMiddleware } from 'astro:middleware';

// public/_headers is applied by Cloudflare only to static assets, so the
// prerender:false routes (compare pages + API) rendered by the SSR Worker ship
// without these headers. Re-apply them here, in sync with the /* block in
// _headers. API responses keep their public CORS/resource-policy behavior.
const SECURITY_HEADERS: Record<string, string> = {
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
  'Strict-Transport-Security': 'max-age=63072000; includeSubDomains; preload',
  'X-XSS-Protection': '0',
  'Cross-Origin-Embedder-Policy': 'credentialless',
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Content-Security-Policy':
    "default-src 'none'; script-src 'self' 'wasm-unsafe-eval' https://static.cloudflareinsights.com; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; img-src 'self' data:; font-src 'self'; connect-src 'self' https://cloudflareinsights.com; worker-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; upgrade-insecure-requests",
};

export const onRequest = defineMiddleware(async (context, next) => {
  const response = await next();
  const isAPI = context.url.pathname.startsWith('/api/');

  for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
    response.headers.set(name, value);
  }
  response.headers.set('Cross-Origin-Resource-Policy', isAPI ? 'cross-origin' : 'same-origin');
  if (isAPI) response.headers.set('Access-Control-Allow-Origin', '*');

  return response;
});
