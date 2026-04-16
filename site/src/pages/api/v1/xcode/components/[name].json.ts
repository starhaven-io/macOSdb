import type { APIRoute } from 'astro';
import { getComponentHistory, getAllComponentSlugs } from '../../../../../lib/api';

export async function getStaticPaths() {
  const slugs = await getAllComponentSlugs('xcode');
  return slugs.map((name) => ({ params: { name } }));
}

export const GET: APIRoute = async ({ params }) => {
  const history = await getComponentHistory('xcode', params.name!);
  if (!history) {
    return new Response(JSON.stringify({ error: 'Component not found' }), {
      status: 404,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
  }
  return new Response(JSON.stringify(history, null, 2), {
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
  });
};
