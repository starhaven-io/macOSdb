#!/usr/bin/env node
// Deploys dist/ with a Wrangler config derived only from the checked-in wrangler.json.
// In the credential-bearing job the build output is untrusted: Wrangler runs a
// generated config's build.command and honors its bindings and routes, and it
// uploads whatever a symlink under dist/ resolves to (such as this process's
// environment) as a module or asset.
import { spawnSync } from 'node:child_process';
import { lstatSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const siteDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export function assertPlainTree(root) {
  const pending = [root];
  while (pending.length > 0) {
    const current = pending.pop();
    const stats = lstatSync(current);
    if (stats.isDirectory()) {
      for (const name of readdirSync(current)) pending.push(path.join(current, name));
    } else if (!stats.isFile()) {
      throw new Error(`Refusing non-regular build output: ${current}`);
    }
  }
}

export function deployConfig(site = siteDir) {
  const config = JSON.parse(readFileSync(path.join(site, 'wrangler.json'), 'utf8'));
  const dist = path.join(site, 'dist');
  const entry = path.join(dist, 'server', 'entry.mjs');
  const assets = path.join(dist, 'client');
  assertPlainTree(dist);
  if (!lstatSync(entry).isFile() || !lstatSync(assets).isDirectory()) {
    throw new Error('Build output lacks server/entry.mjs or client/');
  }
  // Astro's generated config sets these; module discovery under no_bundle needs the rules.
  return {
    ...config,
    main: entry,
    no_bundle: true,
    rules: [{ type: 'ESModule', globs: ['**/*.js', '**/*.mjs'] }],
    assets: { ...config.assets, directory: assets },
  };
}

function deploy(args) {
  const directory = mkdtempSync(path.join(tmpdir(), 'macosdb-deploy-'));
  try {
    const configPath = path.join(directory, 'wrangler.json');
    writeFileSync(configPath, `${JSON.stringify(deployConfig(), null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    const wrangler = path.join(siteDir, 'node_modules', 'wrangler', 'bin', 'wrangler.js');
    // Wrangler loads .env files from its working directory, so it must be the checkout.
    const result = spawnSync(process.execPath, [wrangler, 'deploy', '--config', configPath, ...args], {
      cwd: siteDir,
      stdio: 'inherit',
    });
    if (result.error) throw result.error;
    return result.status ?? 1;
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = deploy(process.argv.slice(2));
}
