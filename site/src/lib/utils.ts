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
