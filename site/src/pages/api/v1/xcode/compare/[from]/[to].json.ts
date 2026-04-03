import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';
import { compareReleases } from '../../../../../../lib/api';

export async function getStaticPaths() {
  const allReleases = await getCollection('xcodeReleases');

  const sorted = allReleases.sort(
    (a, b) => new Date(b.data.releaseDate).getTime() - new Date(a.data.releaseDate).getTime(),
  );

  const paths = [];
  for (let i = 0; i < sorted.length - 1; i++) {
    paths.push({
      params: { from: sorted[i + 1].id, to: sorted[i].id },
    });
  }

  return paths;
}

export const GET: APIRoute = async ({ params }) => {
  const result = await compareReleases('xcode', params.from!, params.to!);
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
