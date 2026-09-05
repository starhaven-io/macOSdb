import type { APIRoute } from 'astro';
import path from 'node:path';
import { loadReleaseIndex, readReleaseDetail, type ReleasePointer } from '../../../../../lib/releaseFiles';

const dataRoot = path.resolve('..', 'data');
const releases = loadReleaseIndex(dataRoot, 'macos', 'macOS');

export function getStaticPaths() {
  return releases.map((release) => {
    const filePath = release.dataFile.replace(/^releases\//, '').replace(/\.json$/, '');
    return {
      params: { path: filePath },
      props: { release },
    };
  });
}

export const GET: APIRoute = ({ props }) => {
  const release = props.release as ReleasePointer;
  const { source } = readReleaseDetail(dataRoot, 'macos', 'macOS', release);

  return new Response(source, {
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
  });
};
