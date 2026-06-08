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

function parseVersion(version: string): number[] {
  const cleaned = version.replace(/\s*\(.*\)/, '').trim();
  return cleaned.split('.').flatMap((segment) => {
    return segment
      .split(/[^0-9]+/)
      .filter(Boolean)
      .map(Number);
  });
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
  const maxLen = Math.max(fromParts.length, toParts.length);

  for (let i = 0; i < maxLen; i++) {
    const f = i < fromParts.length ? fromParts[i] : 0;
    const t = i < toParts.length ? toParts[i] : 0;
    if (f < t) return 'upgraded';
    if (f > t) return 'downgraded';
  }
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
  const len = Math.max(av.length, bv.length);
  for (let i = 0; i < len; i++) {
    const diff = (bv[i] ?? 0) - (av[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return compareBuilds(b.buildNumber, a.buildNumber);
}
