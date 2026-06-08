import { getCollection } from 'astro:content';
import { displayName, releaseSlug, componentSlug, compareVersions, compareReleasesByRecency } from './utils';

export type Product = 'macos' | 'xcode';

interface ComponentSummary {
  name: string;
  version: string;
  source: string;
  path: string;
}

interface VersionChange {
  version: string;
  firstRelease: string;
  firstReleaseSlug: string;
  firstReleaseDate: string;
  firstReleaseBeta: boolean;
  firstReleaseRC: boolean;
  direction: 'upgraded' | 'downgraded' | 'added' | '';
}

interface ComponentHistory {
  name: string;
  source: string;
  path: string;
  changes: VersionChange[];
}

export interface CompareResult {
  from: string;
  to: string;
  summary: {
    upgraded: number;
    downgraded: number;
    added: number;
    removed: number;
    unchanged: number;
  };
  changes: { name: string; from: string; to: string; direction: string }[];
  added: { name: string; version: string }[];
  removed: { name: string; version: string }[];
}

function detailsCollection(product: Product) {
  return product === 'macos' ? 'macosReleaseDetails' : 'xcodeReleaseDetails';
}

function indexCollection(product: Product) {
  return product === 'macos' ? 'macosReleases' : 'xcodeReleases';
}

function productPrefix(product: Product) {
  return product === 'macos' ? 'macOS' : 'Xcode';
}

export async function getComponents(product: Product): Promise<ComponentSummary[]> {
  const allReleases = await getCollection(detailsCollection(product));
  const releases = allReleases.sort(
    (a, b) => new Date(b.data.releaseDate ?? '').getTime() - new Date(a.data.releaseDate ?? '').getTime(),
  );

  const components: Map<string, ComponentSummary> = new Map();
  for (const release of releases) {
    for (const comp of release.data.components) {
      if (!components.has(comp.name)) {
        components.set(comp.name, {
          name: comp.name,
          version: comp.version ?? '',
          source: comp.source,
          path: comp.path,
        });
      }
    }
  }

  return [...components.values()].sort((a, b) => a.name.localeCompare(b.name));
}

export async function getComponentHistory(product: Product, name: string): Promise<ComponentHistory | null> {
  const allReleases = await getCollection(detailsCollection(product));
  const prefix = productPrefix(product);
  const includeReleaseName = product === 'macos';

  interface VersionEntry {
    firstRelease: string;
    firstReleaseSlug: string;
    firstReleaseDate: string;
    firstReleaseBeta: boolean;
    firstReleaseRC: boolean;
    oldestDate: number;
  }

  let meta: { name: string; source: string; path: string } | null = null;
  const versions: Map<string, VersionEntry> = new Map();

  for (const release of allReleases) {
    const releaseDate = new Date(release.data.releaseDate ?? '').getTime();
    for (const comp of release.data.components) {
      if (componentSlug(comp.name) !== name) continue;

      const version = comp.version ?? '';
      if (!meta) {
        meta = { name: comp.name, source: comp.source, path: comp.path };
      }

      const existing = versions.get(version);
      if (!existing || releaseDate < existing.oldestDate) {
        versions.set(version, {
          firstRelease: displayName(release.data, includeReleaseName, prefix),
          firstReleaseSlug: releaseSlug(release.data),
          firstReleaseDate: release.data.releaseDate ?? '',
          firstReleaseBeta: release.data.isBeta,
          firstReleaseRC: release.data.isRC,
          oldestDate: releaseDate,
        });
      }
    }
  }

  if (!meta) return null;

  const sorted = [...versions.entries()].sort(([a], [b]) => {
    const dir = compareVersions(a, b);
    return dir === 'upgraded' ? 1 : dir === 'downgraded' ? -1 : 0;
  });

  const changes: VersionChange[] = sorted.map(([version, entry], i) => ({
    version,
    firstRelease: entry.firstRelease,
    firstReleaseSlug: entry.firstReleaseSlug,
    firstReleaseDate: entry.firstReleaseDate,
    firstReleaseBeta: entry.firstReleaseBeta,
    firstReleaseRC: entry.firstReleaseRC,
    direction: i === sorted.length - 1 ? 'added' : compareVersions(sorted[i + 1][0], version),
  }));

  return { ...meta, changes };
}

// The single "latest" release (used by /releases/latest.json) is the latest GA —
// the endpoint's documented contract is "most recent stable (non-beta, non-RC)".
export async function getLatestRelease(product: Product) {
  return (await getLatestReleases(product)).ga;
}

/**
 * The newest GA release and, when one is newer than that GA, the newest
 * pre-release. `prerelease` is null outside beta season (a shipped GA
 * supersedes its own betas/RC), so callers render one line or two.
 */
export async function getLatestReleases(product: Product) {
  const allReleases = await getCollection(indexCollection(product));
  const sorted = [...allReleases].sort((a, b) => compareReleasesByRecency(a.data, b.data)).map((r) => r.data);
  const ga = sorted.find((r) => !r.isBeta && !r.isRC) ?? null;
  const newestPre = sorted.find((r) => r.isBeta || r.isRC) ?? null;
  const prerelease = newestPre && (!ga || compareReleasesByRecency(newestPre, ga) < 0) ? newestPre : null;
  return { ga, prerelease };
}

export async function compareReleases(product: Product, fromId: string, toId: string): Promise<CompareResult | null> {
  const allReleases = await getCollection(detailsCollection(product));
  const prefix = productPrefix(product);

  const fromRelease = allReleases.find((r) => r.id === fromId);
  const toRelease = allReleases.find((r) => r.id === toId);

  if (!fromRelease || !toRelease) return null;

  const fromMap = new Map(fromRelease.data.components.map((c) => [c.name, c]));
  const toMap = new Map(toRelease.data.components.map((c) => [c.name, c]));
  const allNames = [...new Set([...fromMap.keys(), ...toMap.keys()])].sort();

  const changes: CompareResult['changes'] = [];
  const added: CompareResult['added'] = [];
  const removed: CompareResult['removed'] = [];

  for (const name of allNames) {
    const fromComp = fromMap.get(name);
    const toComp = toMap.get(name);

    if (fromComp && toComp) {
      const fromVer = fromComp.version || '';
      const toVer = toComp.version || '';
      changes.push({ name, from: fromVer, to: toVer, direction: compareVersions(fromVer, toVer) });
    } else if (!fromComp && toComp) {
      added.push({ name, version: toComp.version || '' });
    } else if (fromComp && !toComp) {
      removed.push({ name, version: fromComp.version || '' });
    }
  }

  const includeReleaseName = product === 'macos';

  return {
    from: displayName(fromRelease.data, includeReleaseName, prefix),
    to: displayName(toRelease.data, includeReleaseName, prefix),
    summary: {
      upgraded: changes.filter((c) => c.direction === 'upgraded').length,
      downgraded: changes.filter((c) => c.direction === 'downgraded').length,
      added: added.length,
      removed: removed.length,
      unchanged: changes.filter((c) => c.direction === 'unchanged').length,
    },
    changes,
    added,
    removed,
  };
}

export async function getAllComponentSlugs(product: Product): Promise<string[]> {
  const allReleases = await getCollection(detailsCollection(product));
  const slugs = new Set<string>();
  for (const release of allReleases) {
    for (const comp of release.data.components) {
      slugs.add(componentSlug(comp.name));
    }
  }
  return [...slugs].sort();
}

export interface SDKReleaseEntry {
  sdkBuild: string | null;
  xcodeName: string;
  xcodeSlug: string;
  xcodeBuild: string;
  xcodeReleaseDate: string;
  isBeta: boolean;
  isRC: boolean;
  isFirstShippingBuild: boolean;
}

export interface SDKHistory {
  version: string;
  latestBuild: string | null;
  entries: SDKReleaseEntry[];
}

export async function getAllSDKVersions(): Promise<string[]> {
  const allReleases = await getCollection('xcodeReleaseDetails');
  const versions = new Set<string>();
  for (const release of allReleases) {
    for (const sdk of release.data.sdks ?? []) {
      versions.add(sdk.sdkVersion);
    }
  }
  return [...versions].sort((a, b) => {
    const dir = compareVersions(a, b);
    return dir === 'upgraded' ? 1 : dir === 'downgraded' ? -1 : 0;
  });
}

export async function getSDKHistory(version: string): Promise<SDKHistory | null> {
  const allReleases = await getCollection('xcodeReleaseDetails');

  // Walk oldest-first so we can mark the earliest release for each SDK build.
  const oldestFirst = [...allReleases].sort(
    (a, b) => new Date(a.data.releaseDate ?? '').getTime() - new Date(b.data.releaseDate ?? '').getTime(),
  );

  const seenBuilds = new Set<string>();
  const entries: SDKReleaseEntry[] = [];
  for (const release of oldestFirst) {
    const sdk = release.data.sdks?.find((s) => s.sdkVersion === version);
    if (!sdk) continue;
    const isFirstShipping = sdk.buildVersion ? !seenBuilds.has(sdk.buildVersion) : false;
    if (sdk.buildVersion) seenBuilds.add(sdk.buildVersion);
    entries.push({
      sdkBuild: sdk.buildVersion ?? null,
      xcodeName: displayName(release.data, false, 'Xcode'),
      xcodeSlug: releaseSlug(release.data),
      xcodeBuild: release.data.buildNumber,
      xcodeReleaseDate: release.data.releaseDate ?? '',
      isBeta: release.data.isBeta,
      isRC: release.data.isRC,
      isFirstShippingBuild: isFirstShipping,
    });
  }

  if (entries.length === 0) return null;

  // Reverse to newest-first for display.
  entries.reverse();
  const latestBuild = entries.find((e) => e.sdkBuild)?.sdkBuild ?? null;
  return { version, latestBuild, entries };
}
