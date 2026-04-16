import type { APIRoute } from 'astro';
import { getComponents } from '../../../../../lib/api';

export const GET: APIRoute = async () => {
  const components = await getComponents('macos');
  return new Response(JSON.stringify(components, null, 2), {
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
  });
};
