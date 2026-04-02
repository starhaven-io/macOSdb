import type { APIRoute, GetStaticPaths } from 'astro';
import { getCollection } from 'astro:content';
import satori from 'satori';
import { html } from 'satori-html';
import sharp from 'sharp';
import fs from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const fontRegular = fs.readFileSync(require.resolve('@fontsource/inter/files/inter-latin-400-normal.woff'));
const fontBold = fs.readFileSync(require.resolve('@fontsource/inter/files/inter-latin-700-normal.woff'));

export const getStaticPaths: GetStaticPaths = async () => {
  const releases = await getCollection('xcodeReleases');
  return releases.map((entry) => ({
    params: { slug: `${entry.data.osVersion}-${entry.data.buildNumber}` },
    props: { release: entry.data },
  }));
};

export const GET: APIRoute = async ({ props }) => {
  const release = props.release as {
    osVersion: string;
    buildNumber: string;
    releaseName: string;
    releaseDate: string;
    isBeta: boolean;
    isRC: boolean;
    betaNumber?: number;
  };

  let title = release.releaseName;
  if (release.isBeta && release.betaNumber) {
    title += ` beta ${release.betaNumber}`;
  } else if (release.isRC) {
    title += ' RC';
  }

  const date = new Date(release.releaseDate + 'T00:00:00').toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  });

  const badge = release.isBeta ? 'Beta' : release.isRC ? 'RC' : 'Release';
  const badgeColor = release.isBeta ? '#bf5700' : release.isRC ? '#248a3d' : '#6e6e73';

  const markup = html`<div
    style="display: flex; flex-direction: column; width: 100%; height: 100%; background: #1d1d1f; color: #f5f5f7; padding: 60px;"
  >
    <div style="display: flex; align-items: center; margin-bottom: 40px;">
      <span style="font-size: 32px; font-weight: 700; color: #a1a1a6;">macOSdb</span>
    </div>
    <div style="display: flex; flex-direction: column; flex: 1; justify-content: center;">
      <div style="font-size: 64px; font-weight: 700; line-height: 1.1; margin-bottom: 20px;">${title}</div>
      <div style="display: flex; align-items: center; gap: 20px; margin-top: 10px;">
        <span style="font-size: 28px; color: #a1a1a6;">Build ${release.buildNumber}</span>
        <span style="font-size: 28px; color: #a1a1a6;">${date}</span>
        <span
          style="font-size: 22px; font-weight: 600; padding: 4px 16px; border-radius: 12px; background: ${badgeColor}22; color: ${badgeColor};"
          >${badge}</span
        >
      </div>
    </div>
    <div style="display: flex; align-items: center; justify-content: space-between;">
      <span style="font-size: 24px; color: #424245;">macosdb.com</span>
    </div>
  </div>`;

  const svg = await satori(markup, {
    width: 1200,
    height: 630,
    fonts: [
      {
        name: 'Inter',
        data: Buffer.from(fontRegular),
        weight: 400,
        style: 'normal',
      },
      {
        name: 'Inter',
        data: Buffer.from(fontBold),
        weight: 700,
        style: 'normal',
      },
    ],
  });

  const png = await sharp(Buffer.from(svg)).png().toBuffer();

  return new Response(png, {
    headers: {
      'Content-Type': 'image/png',
      'Cache-Control': 'public, max-age=31536000, immutable',
    },
  });
};
