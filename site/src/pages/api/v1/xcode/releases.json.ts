import type { APIRoute } from 'astro';
import path from 'node:path';
import { readReleaseIndex } from '../../../../lib/releaseFiles';

export const GET: APIRoute = () => {
  const dataDir = path.resolve('..', 'data');
  const { source } = readReleaseIndex(dataDir, 'xcode', 'Xcode');

  return new Response(source, {
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
  });
};
