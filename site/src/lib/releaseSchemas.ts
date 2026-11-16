import { z } from 'astro/zod';

const releaseIndexBaseSchema = z.object({
  id: z.string().min(1),
  productType: z.enum(['macOS', 'Xcode']),
  buildNumber: z.string().min(1),
  osVersion: z.string().min(1),
  releaseName: z.string().min(1),
  releaseDate: z.string().min(1),
  isBeta: z.boolean(),
  isRC: z.boolean(),
  betaNumber: z.number().int().positive().optional(),
  betaRevision: z.number().int().min(2).optional(),
  rcNumber: z.number().int().positive().optional(),
  dataFile: z.string().min(1),
});

const macosReleaseIndexEntrySchema = releaseIndexBaseSchema.extend({
  isDeviceSpecific: z.boolean(),
});

const componentSchema = z.object({
  name: z.string().min(1),
  version: z.string().min(1),
  path: z.string().min(1),
  source: z.enum(['filesystem', 'dyldCache', 'sdk']),
});

const deviceChipSchema = z.object({
  device: z.string().min(1),
  chip: z.string().min(1),
});

const kernelSchema = z.object({
  file: z.string().min(1),
  darwinVersion: z.string().min(1),
  xnuVersion: z.string().min(1),
  arch: z.string().min(1),
  chip: z.string().min(1),
  devices: z.array(z.string().min(1)),
  deviceChips: z.array(deviceChipSchema).optional(),
});

const releaseDetailBaseSchema = z.object({
  id: z.string().min(1),
  buildNumber: z.string().min(1),
  osVersion: z.string().min(1),
  releaseName: z.string().min(1),
  releaseDate: z.string().min(1),
  productType: z.enum(['macOS', 'Xcode']),
  isBeta: z.boolean(),
  isRC: z.boolean(),
  betaNumber: z.number().int().positive().optional(),
  betaRevision: z.number().int().min(2).optional(),
  rcNumber: z.number().int().positive().optional(),
  components: z.array(componentSchema).min(1),
});

const macosReleaseDetailSchema = releaseDetailBaseSchema.extend({
  isDeviceSpecific: z.boolean(),
  components: z.array(componentSchema.extend({ source: z.enum(['filesystem', 'dyldCache']) })).min(1),
  ipswFile: z.string().min(1),
  ipswURL: z.url(),
  kernels: z.array(kernelSchema).min(1),
});

const sdkSchema = z.object({
  sdkVersion: z.string().min(1),
  buildVersion: z.string().min(1),
});

// A release records the pair for the archive format that was scanned.
function recordsOneXcodeSource(release: {
  xipFile?: string;
  xipURL?: string;
  aeaFile?: string;
  aeaURL?: string;
}): boolean {
  const pairs = [
    [release.xipFile, release.xipURL],
    [release.aeaFile, release.aeaURL],
  ];
  const complete = pairs.filter(([file, url]) => file !== undefined && url !== undefined).length;
  const partial = pairs.some(([file, url]) => (file === undefined) !== (url === undefined));
  return complete === 1 && !partial;
}

const xcodeReleaseDetailSchema = releaseDetailBaseSchema
  .extend({
    components: z.array(componentSchema.extend({ source: z.enum(['filesystem', 'sdk']) })).min(1),
    minimumOSVersion: z.string().min(1),
    xipFile: z.string().min(1).optional(),
    xipURL: z.url().optional(),
    aeaFile: z.string().min(1).optional(),
    aeaURL: z.url().optional(),
    sdks: z
      .array(sdkSchema)
      .min(1)
      .refine((sdks) => new Set(sdks.map((sdk) => sdk.sdkVersion)).size === sdks.length, 'Duplicate SDK version'),
  })
  .refine(recordsOneXcodeSource, 'Exactly one source pair is required');

export { releaseIndexBaseSchema, macosReleaseIndexEntrySchema, macosReleaseDetailSchema, xcodeReleaseDetailSchema };
