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
  const { name, source, path, changes, transitions } = history;
  return new Response(JSON.stringify({ name, source, path, changes, transitions }, null, 2), {
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
  });
};
