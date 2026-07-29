import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pickLatestReleases } from '../src/lib/utils.ts';

function release(
  osVersion: string,
  buildNumber: string,
  releaseDate: string,
  flags: Partial<{ isBeta: boolean; isRC: boolean }> = {},
) {
  return { osVersion, buildNumber, releaseDate, isBeta: false, isRC: false, ...flags };
}

test('a pending higher-version beta survives a later current-series GA', () => {
  const releases = [
    release('27.0', '27A5192e', '2026-06-22', { isBeta: true }),
    release('26.6', '17F100', '2026-06-25'),
  ];
  const { ga, prerelease } = pickLatestReleases(releases);
  assert.equal(ga?.buildNumber, '17F100');
  assert.equal(prerelease?.buildNumber, '27A5192e');
});

test('a shipped GA supersedes its prereleases', () => {
  const releases = [
    release('26.0', '25A5295e', '2026-06-01', { isBeta: true }),
    release('26.0', '25A350', '2026-06-10', { isRC: true }),
    release('26.0', '25A354', '2026-06-15'),
  ];
  const { ga, prerelease } = pickLatestReleases(releases);
  assert.equal(ga?.buildNumber, '25A354');
  assert.equal(prerelease, null);
});

test('beta-only history yields no GA', () => {
  const releases = [
    release('27.0', '26A5388g', '2026-07-20', { isBeta: true }),
    release('27.0', '26A5378n', '2026-07-13', { isBeta: true }),
  ];
  const { ga, prerelease } = pickLatestReleases(releases);
  assert.equal(ga, null);
  assert.equal(prerelease?.buildNumber, '26A5388g');
});

test('empty input yields nothing', () => {
  assert.deepEqual(pickLatestReleases([]), { ga: null, prerelease: null });
});
