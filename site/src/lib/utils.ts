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
