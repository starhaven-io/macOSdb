#!/usr/bin/env node
// Guard against drift between the two places security headers are defined:
//
//   * public/_headers — the `/*` block Cloudflare applies to STATIC assets.
//   * src/middleware.ts — the SECURITY_HEADERS the SSR Worker re-applies to
//     prerender:false routes (compare pages + API), which `_headers` does not
//     cover.
//
// Every header in the middleware constant must match the `/*` block byte for
// byte. Cross-Origin-Resource-Policy is intentionally excluded: middleware sets
// it dynamically per-route, so it never appears in SECURITY_HEADERS.
//
// Runs as a `prebuild` step, so `npm run build` (and therefore CI and deploy)
// fail loudly if the two lists ever diverge.

import { readFileSync } from 'node:fs';

const headersPath = new URL('../public/_headers', import.meta.url);
const middlewarePath = new URL('../src/middleware.ts', import.meta.url);

/** Parse the first `/*` block of a Cloudflare _headers file into a map. */
function parseHeadersBlock(text) {
  const out = {};
  let inBlock = false;
  for (const line of text.split('\n')) {
    if (!inBlock) {
      if (line.trimEnd() === '/*') inBlock = true;
      continue;
    }
    // The block ends at the first blank line or the next (unindented) rule.
    if (line.trim() === '' || /^\S/.test(line)) break;
    const match = line.match(/^\s+([A-Za-z0-9-]+):\s*(.+?)\s*$/);
    if (match) out[match[1]] = match[2];
  }
  return out;
}

/** Parse the SECURITY_HEADERS object literal out of middleware.ts into a map. */
function parseMiddlewareHeaders(text) {
  const start = text.indexOf('SECURITY_HEADERS');
  const open = text.indexOf('{', start);
  const close = text.indexOf('};', open);
  if (start === -1 || open === -1 || close === -1) {
    throw new Error('could not locate the SECURITY_HEADERS object in middleware.ts');
  }
  const body = text.slice(open + 1, close);
  const out = {};
  // Matches `'Name': 'value',` and the `'Name':\n  "value",` (CSP) layout, in
  // either quote style. The closing quote is back-referenced so quotes inside
  // the value (e.g. 'self' inside the CSP) do not terminate it early.
  const re = /['"]([A-Za-z0-9-]+)['"]\s*:\s*(['"])([\s\S]*?)\2\s*,/g;
  let match;
  while ((match = re.exec(body)) !== null) out[match[1]] = match[3];
  return out;
}

const staticHeaders = parseHeadersBlock(readFileSync(headersPath, 'utf8'));
const ssrHeaders = parseMiddlewareHeaders(readFileSync(middlewarePath, 'utf8'));

// Defend against a silently-broken parser: if the layout changes such that we
// extract nothing meaningful, fail rather than vacuously pass.
const ssrNames = Object.keys(ssrHeaders);
if (ssrNames.length < 5 || !('Content-Security-Policy' in ssrHeaders)) {
  console.error(
    `check-security-headers: parsed only ${ssrNames.length} header(s) from middleware.ts ` +
      '(expected the full SECURITY_HEADERS set incl. Content-Security-Policy). ' +
      'The middleware layout likely changed — update this script.',
  );
  process.exit(1);
}

const problems = [];
for (const name of ssrNames) {
  if (!(name in staticHeaders)) {
    problems.push(`${name}: present in middleware.ts but missing from the _headers /* block`);
  } else if (staticHeaders[name] !== ssrHeaders[name]) {
    problems.push(
      `${name}: values differ\n    _headers:      ${staticHeaders[name]}\n    middleware.ts: ${ssrHeaders[name]}`,
    );
  }
}

if (problems.length > 0) {
  console.error('check-security-headers: _headers and middleware.ts have drifted:\n');
  for (const problem of problems) console.error(`  - ${problem}`);
  console.error('\nKeep the SSR security headers in sync with the static /* block.');
  process.exit(1);
}

console.log(`check-security-headers: ${ssrNames.length} shared headers in sync.`);
