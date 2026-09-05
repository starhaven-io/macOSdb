import { defineCollection } from 'astro:content';
import { z } from 'astro/zod';
import path from 'node:path';
import { loadReleaseDetails, loadReleaseIndex } from './lib/releaseFiles';

const releaseIndexBaseSchema = z.object({
  id: z.string(),
  productType: z.enum(['macOS', 'Xcode']),
  buildNumber: z.string(),
  osVersion: z.string(),
  releaseName: z.string(),
  releaseDate: z.string(),
  isBeta: z.boolean(),
  isRC: z.boolean(),
  betaNumber: z.number().optional(),
  betaRevision: z.number().optional(),
  rcNumber: z.number().optional(),
  dataFile: z.string(),
});

const macosReleaseIndexEntrySchema = releaseIndexBaseSchema.extend({
  isDeviceSpecific: z.boolean(),
});

const componentSchema = z.object({
  name: z.string(),
  version: z.string(),
  path: z.string(),
  source: z.enum(['filesystem', 'dyldCache', 'sdk']),
});

const deviceChipSchema = z.object({
  device: z.string(),
  chip: z.string(),
});

const kernelSchema = z.object({
  file: z.string(),
  darwinVersion: z.string(),
  xnuVersion: z.string(),
  arch: z.string(),
  chip: z.string(),
  devices: z.array(z.string()),
  deviceChips: z.array(deviceChipSchema).optional(),
});

const releaseDetailBaseSchema = z.object({
  id: z.string(),
  buildNumber: z.string(),
  osVersion: z.string(),
  releaseName: z.string(),
  releaseDate: z.string(),
  productType: z.enum(['macOS', 'Xcode']),
  isBeta: z.boolean(),
  isRC: z.boolean(),
  betaNumber: z.number().optional(),
  betaRevision: z.number().optional(),
  rcNumber: z.number().optional(),
  components: z.array(componentSchema),
});

const macosReleaseDetailSchema = releaseDetailBaseSchema.extend({
  isDeviceSpecific: z.boolean(),
  ipswFile: z.string(),
  ipswURL: z.url(),
  kernels: z.array(kernelSchema),
});

const sdkSchema = z.object({
  sdkVersion: z.string(),
  buildVersion: z.string(),
});

const xcodeReleaseDetailSchema = releaseDetailBaseSchema.extend({
  minimumOSVersion: z.string(),
  xipFile: z.string(),
  xipURL: z.url(),
  sdks: z.array(sdkSchema).min(1),
});

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
