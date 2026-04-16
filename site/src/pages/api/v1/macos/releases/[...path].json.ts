import type { APIRoute } from 'astro';
import fs from 'node:fs';
import path from 'node:path';

const dataDir = path.resolve('..', 'data', 'macos');
const releases = JSON.parse(fs.readFileSync(path.join(dataDir, 'releases.json'), 'utf-8'));

export function getStaticPaths() {
  return releases.map((release: any) => {
    // dataFile is e.g. "releases/26/macOS-26.4-25E246.json"
    // Strip leading "releases/" (already in the URL path) and trailing ".json" (added by Astro)
    const filePath = release.dataFile.replace(/^releases\//, '').replace(/\.json$/, '');
    return {
      params: { path: filePath },
      props: { dataFile: release.dataFile },
    };
  });
}

export const GET: APIRoute = ({ props }) => {
  const data = fs.readFileSync(path.join(dataDir, props.dataFile), 'utf-8');

  return new Response(data, {
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
  });
};
