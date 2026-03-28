import type { APIRoute } from 'astro';
import fs from 'node:fs';
import path from 'node:path';

export const GET: APIRoute = () => {
  const dataDir = path.resolve('..', 'data');
  const releases = fs.readFileSync(path.join(dataDir, 'macos', 'releases.json'), 'utf-8');

  return new Response(releases, {
    headers: { 'Content-Type': 'application/json' },
  });
};
