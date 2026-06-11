import type { APIRoute } from 'astro';
import { compareReleases } from '../../../../../../lib/api';

export const prerender = false;

export const GET: APIRoute = async ({ params }) => {
  const result = await compareReleases('macos', params.from!, params.to!);
  if (!result) {
    return new Response(JSON.stringify({ error: 'One or both releases not found' }), {
      status: 404,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        // The valid (from, to) set only changes on deploy; cache the miss briefly.
        'Cache-Control': 'public, max-age=300',
      },
    });
  }
  return new Response(JSON.stringify(result, null, 2), {
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
      // Deterministic per (from, to) for a given deploy — same policy as the static API.
      'Cache-Control': 'public, max-age=3600, s-maxage=86400, stale-while-revalidate=604800',
    },
  });
};
