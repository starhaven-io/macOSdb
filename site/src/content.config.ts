import { defineCollection } from 'astro:content';
import { file } from 'astro/loaders';
import { z } from 'astro/zod';
import fs from 'node:fs';
import path from 'node:path';

const releaseIndexBaseSchema = z.object({
  id: z.string(),
  buildNumber: z.string(),
  osVersion: z.string(),
  releaseName: z.string(),
  releaseDate: z.string(),
  isBeta: z.boolean(),
  isRC: z.boolean(),
  betaNumber: z.number().optional(),
  rcNumber: z.number().optional(),
  dataFile: z.string(),
});

const macosReleaseIndexEntrySchema = releaseIndexBaseSchema.extend({
  isDeviceSpecific: z.boolean(),
});

const componentSchema = z.object({
  name: z.string(),
  version: z.string().nullable().optional(),
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
  xnuVersion: z.string().nullable().optional(),
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
  releaseDate: z.string().optional(),
  isBeta: z.boolean(),
  isRC: z.boolean(),
  betaNumber: z.number().optional(),
  rcNumber: z.number().optional(),
  components: z.array(componentSchema),
});

const macosReleaseDetailSchema = releaseDetailBaseSchema.extend({
  isDeviceSpecific: z.boolean().optional(),
  ipswFile: z.string().optional(),
  ipswURL: z.string().optional(),
  kernels: z.array(kernelSchema),
});

const sdkSchema = z.object({
  sdkVersion: z.string(),
});

const xcodeReleaseDetailSchema = releaseDetailBaseSchema.extend({
  minimumOSVersion: z.string().optional(),
  xipFile: z.string().optional(),
  xipURL: z.string().optional(),
  sdks: z.array(sdkSchema).optional(),
});

const macosReleases = defineCollection({
  loader: file('../data/macos/releases.json', {
    parser: (text) =>
      JSON.parse(text).map((r: Record<string, unknown>) => ({
        ...r,
        id: `${r.osVersion}-${r.buildNumber}`,
      })),
  }),
  schema: macosReleaseIndexEntrySchema,
});

const macosReleaseDetails = defineCollection({
  loader: async () => {
    const dataDir = path.resolve('..', 'data');
    const index = JSON.parse(fs.readFileSync(path.join(dataDir, 'macos', 'releases.json'), 'utf-8'));
    return index.map((entry: Record<string, unknown>) => {
      const data = JSON.parse(fs.readFileSync(path.join(dataDir, 'macos', entry.dataFile as string), 'utf-8'));
      return {
        id: `${entry.osVersion}-${entry.buildNumber}`,
        ...data,
      };
    });
  },
  schema: macosReleaseDetailSchema,
});

const xcodeReleases = defineCollection({
  loader: file('../data/xcode/releases.json', {
    parser: (text) =>
      JSON.parse(text).map((r: Record<string, unknown>) => ({
        ...r,
        id: `${r.osVersion}-${r.buildNumber}`,
      })),
  }),
  schema: releaseIndexBaseSchema,
});

const xcodeReleaseDetails = defineCollection({
  loader: async () => {
    const dataDir = path.resolve('..', 'data');
    const index = JSON.parse(fs.readFileSync(path.join(dataDir, 'xcode', 'releases.json'), 'utf-8'));
    return index.map((entry: Record<string, unknown>) => {
      const data = JSON.parse(fs.readFileSync(path.join(dataDir, 'xcode', entry.dataFile as string), 'utf-8'));
      return {
        id: `${entry.osVersion}-${entry.buildNumber}`,
        ...data,
      };
    });
  },
  schema: xcodeReleaseDetailSchema,
});

export const collections = { macosReleases, macosReleaseDetails, xcodeReleases, xcodeReleaseDetails };
