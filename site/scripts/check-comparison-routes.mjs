import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const siteRoot = fileURLToPath(new URL('..', import.meta.url));
const child = spawn(
  process.execPath,
  [
    'node_modules/wrangler/bin/wrangler.js',
    'dev',
    '--config',
    'dist/server/wrangler.json',
    '--local',
    '--ip',
    '127.0.0.1',
    '--port',
    '0',
    '--inspector-port',
    '0',
  ],
  {
    cwd: siteRoot,
    env: { ...process.env, NO_COLOR: '1', WRANGLER_SEND_METRICS: 'false', WRANGLER_WRITE_LOGS: 'false' },
    stdio: ['ignore', 'pipe', 'pipe'],
  },
);
let output = '';
let exited = false;
let launchError;
const closed = new Promise((resolve) => child.once('close', resolve));
child.once('exit', () => {
  exited = true;
});
child.once('error', (error) => {
  launchError = error;
});
for (const stream of [child.stdout, child.stderr]) {
  stream.setEncoding('utf8');
  stream.on('data', (data) => {
    output = (output + data).slice(-65536);
  });
}

try {
  const deadline = Date.now() + 45000;
  let origin;
  while (!origin && Date.now() < deadline) {
    if (launchError) throw launchError;
    assert.equal(exited, false, `Local Worker exited before readiness:\n${output}`);
    origin = output.match(/http:\/\/127\.0\.0\.1:\d+/)?.[0];
    if (!origin) await delay(100);
  }
  assert.ok(origin, `Local Worker did not become ready:\n${output}`);
  console.log(`Checking local Worker at ${origin}`);
  for (const [path, status] of [
    ['/macos/compare/', 200],
    ['/macos/compare/?from=missing', 404],
    ['/xcode/compare/?to=missing', 404],
    ['/xcode/compare/?from=&to=', 200],
    ['/macos/compare/?from=15.0-24A335&to=15.1-24B83', 200],
  ]) {
    console.log(`Checking ${path}`);
    const response = await fetch(origin + path, { signal: AbortSignal.timeout(30000), redirect: 'manual' });
    assert.equal(response.status, status, path);
    const body = await response.text();
    if (status === 404) {
      assert.equal(response.headers.get('cache-control'), 'no-store', path);
      assert.ok(body.includes('A selected release could not be found'), path);
    } else {
      assert.ok(response.headers.get('cache-control')?.includes('public'), path);
    }
  }
  console.log('check-comparison-routes: five built Worker routes have the expected status and cache policy.');
} catch (error) {
  console.error(output);
  throw error;
} finally {
  child.kill('SIGTERM');
  const killTimer = setTimeout(() => child.kill('SIGKILL'), 5000);
  try {
    await closed;
  } finally {
    clearTimeout(killTimer);
  }
}
