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

export function displayName(release: ReleaseEntry, includeReleaseName = false): string {
  let name = `macOS ${release.osVersion}`;
  if (includeReleaseName && release.releaseName) {
    name += ` ${release.releaseName}`;
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
