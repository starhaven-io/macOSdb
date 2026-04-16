import type { APIRoute } from 'astro';
import { getLatestRelease } from '../../../../../lib/api';

export const GET: APIRoute = async () => {
  const latest = await getLatestRelease('xcode');
  if (!latest) {
    return new Response(JSON.stringify({ error: 'No release found' }), {
      status: 404,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
  }
  return new Response(JSON.stringify(latest, null, 2), {
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
  });
};
