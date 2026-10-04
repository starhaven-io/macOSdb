import { defineCollection } from 'astro:content';
import {
  releaseIndexBaseSchema,
  macosReleaseIndexEntrySchema,
  macosReleaseDetailSchema,
  xcodeReleaseDetailSchema,
} from './lib/releaseSchemas';
import path from 'node:path';
import { loadReleaseDetails, loadReleaseIndex } from './lib/releaseFiles';

const macosReleases = defineCollection({
  loader: async () =>
    loadReleaseIndex(path.resolve('..', 'data'), 'macos', 'macOS').map((release) => ({
      ...release,
      id: `${release.osVersion}-${release.buildNumber}`,
    })),
  schema: macosReleaseIndexEntrySchema,
});

const macosReleaseDetails = defineCollection({
  loader: async () => loadReleaseDetails(path.resolve('..', 'data'), 'macos', 'macOS'),
  schema: macosReleaseDetailSchema,
});

const xcodeReleases = defineCollection({
  loader: async () =>
    loadReleaseIndex(path.resolve('..', 'data'), 'xcode', 'Xcode').map((release) => ({
      ...release,
      id: `${release.osVersion}-${release.buildNumber}`,
    })),
  schema: releaseIndexBaseSchema,
});

const xcodeReleaseDetails = defineCollection({
  loader: async () => loadReleaseDetails(path.resolve('..', 'data'), 'xcode', 'Xcode'),
  schema: xcodeReleaseDetailSchema,
});

export const collections = { macosReleases, macosReleaseDetails, xcodeReleases, xcodeReleaseDetails };
