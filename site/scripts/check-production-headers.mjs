#!/usr/bin/env node
import { readFileSync } from 'node:fs';

const origin = process.argv[2] ?? 'https://macosdb.com';
const releases = JSON.parse(readFileSync(new URL('../../data/macos/releases.json', import.meta.url), 'utf8'));
if (!Array.isArray(releases) || releases.length < 2) {
  throw new Error('production header check needs at least two macOS releases');
}
const releaseIDs = releases
  .slice(0, 2)
  .map((release) => encodeURIComponent(`${release.osVersion}-${release.buildNumber}`));
const expected = {};
let inRoot = false;
for (const line of readFileSync(new URL('../public/_headers', import.meta.url), 'utf8').split('\n')) {
  if (!inRoot) {
    if (line.trimEnd() === '/*') inRoot = true;
    continue;
  }
  if (line.trim() === '' || /^\S/.test(line)) break;
  const match = line.match(/^\s+([A-Za-z0-9-]+):\s*(.+?)\s*$/);
  if (match) expected[match[1].toLowerCase()] = match[2];
}

async function inspect(url, api) {
  const response = await fetch(url, { headers: { 'cache-control': 'no-cache' }, redirect: 'error' });
  if (!response.ok) throw new Error(`${url} returned HTTP ${response.status}`);
  for (const [name, value] of Object.entries(expected)) {
    const routeValue = api && name === 'cross-origin-resource-policy' ? 'cross-origin' : value;
    if (response.headers.get(name) !== routeValue) {
      throw new Error(
        `${url}: ${name} was ${JSON.stringify(response.headers.get(name))}, expected ${JSON.stringify(routeValue)}`,
      );
    }
  }
  if (api && response.headers.get('access-control-allow-origin') !== '*') {
    throw new Error(`${url}: API CORS header is missing or incorrect`);
  }
}

let lastError;
for (let attempt = 1; attempt <= 8; attempt++) {
  try {
    const marker = encodeURIComponent(process.env.GITHUB_SHA ?? String(Date.now()));
    await inspect(`${origin}/?deployment=${marker}`, false);
    await inspect(`${origin}/api/v1/macos/releases/latest.json?deployment=${marker}`, true);
    await inspect(`${origin}/api/v1/macos/compare/${releaseIDs[0]}/${releaseIDs[1]}.json?deployment=${marker}`, true);
    console.log('Production static and SSR security headers match the deployed policy.');
    process.exit(0);
  } catch (error) {
    lastError = error;
    if (attempt < 8) await new Promise((resolve) => setTimeout(resolve, 10_000));
  }
}
console.error(lastError instanceof Error ? lastError.message : lastError);
process.exit(1);
