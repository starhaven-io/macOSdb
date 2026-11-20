import {
  compareReleasesByRecency,
  compareVersions,
  componentSlug,
  displayName,
  releaseSlug,
  type DatedRelease,
} from './utils.ts';

interface HistoryRelease extends DatedRelease {
  releaseName?: string;
  betaNumber?: number;
  betaRevision?: number;
  rcNumber?: number;
  components: { name: string; version: string; source: string; path: string }[];
}

export interface HistoryChange {
  version: string;
  firstRelease: string;
  firstReleaseSlug: string;
  firstReleaseDate: string;
  firstReleaseBeta: boolean;
  firstReleaseRC: boolean;
  direction: 'upgraded' | 'downgraded' | 'added' | 'unchanged';
}

interface Observation {
  version: string;
  slug: string;
}

export interface HistoryTransition extends HistoryChange {
  previousVersion: string | null;
  previousReleaseSlug: string | null;
}

function releaseFields(version: string, release: HistoryRelease, product: 'macOS' | 'Xcode') {
  return {
    version,
    firstRelease: displayName(release, product === 'macOS', product),
    firstReleaseSlug: releaseSlug(release),
    firstReleaseDate: release.releaseDate,
    firstReleaseBeta: release.isBeta,
    firstReleaseRC: release.isRC,
  };
}

function nearestObservation(series: Map<number, Observation>, maximum: number) {
  const key = [...series.keys()].sort((a, b) => b - a).find((version) => version <= maximum);
  return key === undefined ? undefined : series.get(key);
}

export function componentHistory(releases: HistoryRelease[], slug: string, product: 'macOS' | 'Xcode') {
  const firstReleases = new Map<string, HistoryRelease>();
  const matches = releases.flatMap((release) =>
    release.components.filter((item) => componentSlug(item.name) === slug).map((component) => ({ release, component })),
  );
  if (!matches.length) return null;
  // The v1 first-appearance list retains collection order when two releases have the same date.
  for (const { release, component } of matches) {
    const first = firstReleases.get(component.version);
    if (!first || release.releaseDate < first.releaseDate) firstReleases.set(component.version, release);
  }
  const versions = [...firstReleases.keys()].sort((a, b) => {
    const direction = compareVersions(a, b);
    return direction === 'upgraded' ? 1 : direction === 'downgraded' ? -1 : 0;
  });
  const changes: HistoryChange[] = versions.map((version, index) => ({
    ...releaseFields(version, firstReleases.get(version)!, product),
    direction: index === versions.length - 1 ? 'added' : compareVersions(versions[index + 1], version),
  }));

  const observations = new Map<number, Map<number, Observation>>();
  const lastInMajor = new Map<number, Observation>();
  const transitions: HistoryTransition[] = [];
  matches.sort((a, b) => compareReleasesByRecency(b.release, a.release));
  for (const { release, component } of matches) {
    const [major, minor = 0] = release.osVersion.split('.').map(Number);
    const series = observations.get(major) ?? new Map<number, Observation>();
    observations.set(major, series);
    const predecessor = nearestObservation(series, minor) ?? nearestObservation(lastInMajor, major - 1);
    const current = { version: component.version, slug: releaseSlug(release) };
    series.set(minor, current);
    lastInMajor.set(major, current);
    if (predecessor?.version === component.version) continue;

    transitions.push({
      ...releaseFields(component.version, release, product),
      direction: predecessor ? compareVersions(predecessor.version, component.version) : 'added',
      previousVersion: predecessor?.version ?? null,
      previousReleaseSlug: predecessor?.slug ?? null,
    });
  }

  const latest = matches[matches.length - 1].component;
  return {
    name: latest.name,
    source: latest.source,
    path: latest.path,
    latestVersion: latest.version,
    changes,
    transitions: transitions.reverse(),
  };
}
