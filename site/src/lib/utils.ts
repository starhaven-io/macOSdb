interface ReleaseEntry {
  osVersion: string;
  buildNumber: string;
  releaseName?: string;
  isBeta: boolean;
  isRC: boolean;
  betaNumber?: number;
  rcNumber?: number;
}

export function formatDate(dateStr: string, style: 'short' | 'long' = 'short'): string {
  return new Date(dateStr + 'T00:00:00').toLocaleDateString('en-US', {
    year: 'numeric',
    month: style === 'long' ? 'long' : 'short',
    day: 'numeric',
  });
}

export function displayName(release: ReleaseEntry, includeReleaseName = false, productPrefix = 'macOS'): string {
  let name: string;
  if (productPrefix === 'Xcode') {
    name = `Xcode ${release.osVersion}`;
  } else {
    name = `macOS ${release.osVersion}`;
    if (includeReleaseName && release.releaseName) {
      name += ` ${release.releaseName}`;
    }
  }
  if (release.isBeta && release.betaNumber) {
    name += ` beta ${release.betaNumber}`;
  } else if (release.isRC) {
    name += ' RC';
    if (release.rcNumber) {
      name += ` ${release.rcNumber}`;
    }
  }
  return name;
}

export function releaseSlug(release: ReleaseEntry): string {
  return `${release.osVersion}-${release.buildNumber}`;
}

export function componentSlug(name: string): string {
  return name
    .replace(/\s*\(.*\)/, '')
    .trim()
    .toLowerCase();
}

type VersionToken = { kind: 'number'; value: number } | { kind: 'letters'; value: string };

function parseVersion(version: string): VersionToken[] {
  const cleaned = version.replace(/\s*\([^)]*\)/g, '').trim();
  const tokens: VersionToken[] = [];

  for (const match of cleaned.matchAll(/\d+|[A-Za-z]+/g)) {
    const value = match[0];
    if (/^\d+$/.test(value)) {
      tokens.push({ kind: 'number', value: Number(value) || 0 });
    } else if (tokens.length > 0) {
      tokens.push({ kind: 'letters', value: value.toLowerCase() });
    }
  }

  return tokens;
}

function compareValues<T>(lhs: T, rhs: T): number {
  if (lhs < rhs) return -1;
  if (lhs > rhs) return 1;
  return 0;
}

function compareToken(lhs: VersionToken | undefined, rhs: VersionToken | undefined): number {
  if (!lhs && !rhs) return 0;
  if (lhs?.kind === 'number' && lhs.value === 0 && !rhs) return 0;
  if (!lhs && rhs?.kind === 'number' && rhs.value === 0) return 0;
  if (!lhs) return -1;
  if (!rhs) return 1;

  if (lhs.kind === 'number' && rhs.kind === 'number') {
    return compareValues(lhs.value, rhs.value);
  }
  if (lhs.kind === 'letters' && rhs.kind === 'letters') {
    return compareValues(lhs.value, rhs.value);
  }
  if (lhs.kind === 'number' && rhs.kind === 'letters') {
    return lhs.value === 0 ? -1 : 1;
  }
  return rhs.value === 0 ? 1 : -1;
}

function compareParsedVersions(lhs: VersionToken[], rhs: VersionToken[]): number {
  const maxLen = Math.max(lhs.length, rhs.length);

  for (let i = 0; i < maxLen; i++) {
    const result = compareToken(lhs[i], rhs[i]);
    if (result !== 0) return result;
  }

  return 0;
}

// Kernel grouping for release detail pages

interface KernelInput {
  darwinVersion: string;
  xnuVersion?: string | null;
  arch: string;
  chip: string;
  file: string;
  deviceChips?: { device: string; chip: string }[];
}

export interface KernelRow {
  chips: string[];
  arch: string;
  file: string;
  isDev: boolean;
}

export interface KernelSummary {
  darwinVersion: string;
  xnuVersion: string | null;
  rows: KernelRow[];
}

/**
 * Parse chip generation and tier from a chip name like "M4 Pro".
 * Returns [generation, tierRank] for sorting (higher generation first,
 * base < Pro < Max < Ultra within a generation).
 */
function chipSortKey(chip: string): [number, number] {
  const match = chip.match(/^M(\d+)\s*(Pro|Max|Ultra)?$/);
  if (!match) {
    if (chip.includes('Virtual')) return [0, 0];
    return [0, 1]; // Unknown chips sort near the end
  }
  const gen = parseInt(match[1], 10);
  const tier = match[2];
  const tierRank = tier === 'Ultra' ? 3 : tier === 'Max' ? 2 : tier === 'Pro' ? 1 : 0;
  return [gen, tierRank];
}

export function groupKernels(kernels: KernelInput[]): KernelSummary | null {
  if (!kernels || kernels.length === 0) return null;

  const darwinVersion = kernels[0].darwinVersion;
  const xnuVersion = kernels[0].xnuVersion ?? null;

  const rows: KernelRow[] = kernels.map((k) => {
    const chips: string[] = [];
    if (k.deviceChips && k.deviceChips.length > 0) {
      for (const dc of k.deviceChips) {
        if (!chips.includes(dc.chip)) chips.push(dc.chip);
      }
      // Sort chips within a row by tier (base, Pro, Max, Ultra)
      chips.sort((a, b) => {
        const [, aTier] = chipSortKey(a);
        const [, bTier] = chipSortKey(b);
        return aTier - bTier;
      });
    } else {
      chips.push(k.chip);
    }
    return {
      chips,
      arch: k.arch,
      file: k.file,
      isDev: k.file.includes('development'),
    };
  });

  // Sort: release before dev, then by chip generation descending, Virtual Mac last
  rows.sort((a, b) => {
    if (a.isDev !== b.isDev) return a.isDev ? 1 : -1;
    const [aGen, aTier] = chipSortKey(a.chips[0]);
    const [bGen, bTier] = chipSortKey(b.chips[0]);
    if (aGen !== bGen) return bGen - aGen;
    return aTier - bTier;
  });

  return { darwinVersion, xnuVersion, rows };
}

export function compareVersions(from: string, to: string): 'upgraded' | 'downgraded' | 'unchanged' {
  const fromParts = parseVersion(from);
  const toParts = parseVersion(to);

  if (fromParts.length === 0 || toParts.length === 0) {
    return 'unchanged';
  }

  const result = compareParsedVersions(fromParts, toParts);
  if (result < 0) return 'upgraded';
  if (result > 0) return 'downgraded';
  return 'unchanged';
}

interface DatedRelease {
  osVersion: string;
  buildNumber: string;
  releaseDate: string;
  isBeta: boolean;
  isRC: boolean;
}

/**
 * Order Apple build numbers within a train numerically, e.g. 25F71 < 25F5068a.
 * Splits "25F5068a" into [cycle 25, train "F", build 5068, suffix "a"].
 */
function parseBuild(build: string): [number, string, number, string] {
  const m = build.match(/^(\d+)([A-Za-z]+)(\d+)(.*)$/);
  if (!m) return [0, '', 0, build];
  return [Number(m[1]), m[2], Number(m[3]), m[4]];
}

function compareBuilds(a: string, b: string): number {
  const [aCycle, aTrain, aBuild, aSuffix] = parseBuild(a);
  const [bCycle, bTrain, bBuild, bSuffix] = parseBuild(b);
  if (aCycle !== bCycle) return aCycle - bCycle;
  if (aTrain !== bTrain) return aTrain < bTrain ? -1 : 1;
  if (aBuild !== bBuild) return aBuild - bBuild;
  return aSuffix < bSuffix ? -1 : aSuffix > bSuffix ? 1 : 0;
}

/**
 * Order releases newest-first. Date is the primary key because Apple ships a
 * GA with a *lower* build number than its own betas (25F71 GA lands after the
 * 25F5068a beta), so build order can't stand in for chronology. Releases that
 * share a date — a new-major beta and a prior-major RC dropping together at
 * WWDC, say — are broken by version, then build.
 */
export function compareReleasesByRecency(a: DatedRelease, b: DatedRelease): number {
  const byDate = new Date(b.releaseDate).getTime() - new Date(a.releaseDate).getTime();
  if (byDate !== 0) return byDate;
  const av = parseVersion(a.osVersion);
  const bv = parseVersion(b.osVersion);
  const byVersion = compareParsedVersions(bv, av);
  if (byVersion !== 0) return byVersion;
  return compareBuilds(b.buildNumber, a.buildNumber);
}

/**
 * Returns a download URL only if it is a plain https link. IPSW/XIP URLs come from
 * the data files and are rendered as <a href>, so a non-https scheme (javascript:,
 * data:, http:) must never become a clickable link.
 */
export function httpsDownloadURL(url?: string): string | undefined {
  return url?.startsWith('https://') ? url : undefined;
}
