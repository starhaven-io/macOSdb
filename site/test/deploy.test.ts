import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { deployConfig } from '../scripts/deploy.mjs';

function fixture() {
  const site = fs.mkdtempSync(path.join(os.tmpdir(), 'macosdb-deploy-test-'));
  fs.writeFileSync(
    path.join(site, 'wrangler.json'),
    JSON.stringify({ name: 'macosdb', assets: { binding: 'ASSETS', directory: './dist/client' } }),
  );
  fs.mkdirSync(path.join(site, 'dist', 'server', 'chunks'), { recursive: true });
  fs.mkdirSync(path.join(site, 'dist', 'client'), { recursive: true });
  fs.writeFileSync(path.join(site, 'dist', 'server', 'entry.mjs'), 'export default {};\n');
  fs.writeFileSync(path.join(site, 'dist', 'server', 'wrangler.json'), JSON.stringify({ build: { command: 'false' } }));
  fs.writeFileSync(path.join(site, 'dist', 'client', 'index.html'), '<!doctype html>\n');
  return site;
}

test('deployConfig uses the checked-in config and ignores generated build settings', () => {
  const site = fixture();
  const config = deployConfig(site);
  assert.equal(config.name, 'macosdb');
  assert.equal(config.main, path.join(site, 'dist', 'server', 'entry.mjs'));
  assert.deepEqual(config.assets, { binding: 'ASSETS', directory: path.join(site, 'dist', 'client') });
  assert.equal(config.no_bundle, true);
  assert.equal(config.build, undefined);
});

test('deployConfig rejects symlinks anywhere in the build output', () => {
  for (const link of [
    ['server', 'chunks', 'environ.mjs'],
    ['client', 'leak.txt'],
  ]) {
    const site = fixture();
    fs.symlinkSync('/proc/self/environ', path.join(site, 'dist', ...link));
    assert.throws(() => deployConfig(site), /non-regular build output/);
  }
});

test('deployConfig requires the server entry', () => {
  const site = fixture();
  fs.rmSync(path.join(site, 'dist', 'server', 'entry.mjs'));
  assert.throws(() => deployConfig(site));
});
