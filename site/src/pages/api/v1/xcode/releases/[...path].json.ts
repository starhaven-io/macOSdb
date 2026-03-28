import type { APIRoute } from 'astro';
import fs from 'node:fs';
import path from 'node:path';

const dataDir = path.resolve('..', 'data', 'xcode');
const releases = JSON.parse(fs.readFileSync(path.join(dataDir, 'releases.json'), 'utf-8'));

export function getStaticPaths() {
  return releases.map((release: any) => {
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
    headers: { 'Content-Type': 'application/json' },
  });
};
