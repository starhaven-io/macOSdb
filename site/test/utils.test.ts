import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  chipSortKey,
  componentSlug,
  compareReleasesByRecency,
  displayName,
  groupKernels,
  httpsDownloadURL,
} from '../src/lib/utils.ts';

test('groupKernels orders A18 Pro with the M5 family', () => {
  const kernels = [
    { darwinVersion: '27.0.0', arch: 'arm64e', chip: 'M1', file: 'kernelcache.release.mac13g' },
    { darwinVersion: '27.0.0', arch: 'arm64e', chip: 'Virtual Mac', file: 'kernelcache.release.vma2' },
    { darwinVersion: '27.0.0', arch: 'arm64e', chip: 'A18 Pro', file: 'kernelcache.release.mac17p' },
    { darwinVersion: '27.0.0', arch: 'arm64e', chip: 'M4', file: 'kernelcache.release.mac16g' },
    { darwinVersion: '27.0.0', arch: 'arm64e', chip: 'M5', file: 'kernelcache.release.mac17g' },
  ];
  const summary = groupKernels(kernels);
  assert.ok(summary);
  assert.deepEqual(
    summary.rows.map((row) => row.chips[0]),
    ['M5', 'A18 Pro', 'M4', 'M1', 'Virtual Mac'],
  );
});

test('chipSortKey handles only the known A-series Mac mapping', () => {
  assert.deepEqual(chipSortKey('A18 Pro'), [5, 4]);
  assert.deepEqual(chipSortKey('A17 Pro'), [0, 1]);
});

test('chipSortKey keeps M-series tier order', () => {
  const chips = ['M4 Ultra', 'M4', 'M4 Max', 'M4 Pro'];
  chips.sort((a, b) => chipSortKey(a)[1] - chipSortKey(b)[1]);
  assert.deepEqual(chips, ['M4', 'M4 Pro', 'M4 Max', 'M4 Ultra']);
});

test('release recency uses date before build number', () => {
  const ga = { osVersion: '15.5', buildNumber: '25F71', releaseDate: '2025-05-12', isBeta: false, isRC: false };
  const beta = { osVersion: '15.5', buildNumber: '25F5068a', releaseDate: '2025-04-25', isBeta: true, isRC: false };
  assert.ok(compareReleasesByRecency(ga, beta) < 0);
  assert.ok(compareReleasesByRecency(beta, ga) > 0);
});

test('release recency breaks same-day ties by version then build', () => {
  const rc = { osVersion: '26.0', buildNumber: '25A353', releaseDate: '2026-06-09', isBeta: false, isRC: true };
  const beta = { osVersion: '27.0', buildNumber: '26A5305p', releaseDate: '2026-06-09', isBeta: true, isRC: false };
  assert.ok(compareReleasesByRecency(beta, rc) < 0);

  const original = { osVersion: '15.1', buildNumber: '24B83', releaseDate: '2024-10-28', isBeta: false, isRC: false };
  const rerelease = {
    osVersion: '15.1',
    buildNumber: '24B2083',
    releaseDate: '2024-10-28',
    isBeta: false,
    isRC: false,
  };
  assert.ok(compareReleasesByRecency(rerelease, original) < 0);
});

test('displayName renders beta revisions and RC numbers', () => {
  assert.equal(
    displayName({ osVersion: '27.0', buildNumber: 'x', isBeta: true, isRC: false, betaNumber: 3, betaRevision: 2 }),
    'macOS 27.0 beta 3 v.2',
  );
  assert.equal(
    displayName({ osVersion: '26.0', buildNumber: 'x', isBeta: false, isRC: true, rcNumber: 2 }, false, 'Xcode'),
    'Xcode 26.0 RC 2',
  );
});

test('componentSlug strips parentheticals', () => {
  assert.equal(componentSlug('libbz2 (bzip2)'), 'libbz2');
  assert.equal(componentSlug('LibreSSL'), 'libressl');
});

test('httpsDownloadURL only passes HTTPS links', () => {
  assert.equal(httpsDownloadURL('https://updates.cdn-apple.com/a.ipsw'), 'https://updates.cdn-apple.com/a.ipsw');
  assert.equal(httpsDownloadURL('http://updates.cdn-apple.com/a.ipsw'), undefined);
  assert.equal(httpsDownloadURL('javascript:alert(1)'), undefined);
  assert.equal(httpsDownloadURL(undefined), undefined);
});
