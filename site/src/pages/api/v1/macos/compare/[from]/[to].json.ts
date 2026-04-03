import type { APIRoute } from 'astro';
import { compareReleases } from '../../../../../../lib/api';

export const prerender = false;

export const GET: APIRoute = async ({ params }) => {
  const result = await compareReleases('macos', params.from!, params.to!);
  if (!result) {
    return new Response(JSON.stringify({ error: 'One or both releases not found' }), {
      status: 404,
      headers: { 'Content-Type': 'application/json' },
    });
  }
  return new Response(JSON.stringify(result, null, 2), {
    headers: { 'Content-Type': 'application/json' },
  });
};
