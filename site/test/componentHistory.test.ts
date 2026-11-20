import assert from 'node:assert/strict';
import test from 'node:test';
import { componentHistory } from '../src/lib/componentHistory.ts';

function release(osVersion: string, buildNumber: string, releaseDate: string, version: string) {
  return {
    osVersion,
    buildNumber,
    releaseDate,
    isBeta: false,
    isRC: false,
    components: [{ name: 'sqlite3', version, path: '/sqlite.h', source: 'sdk' }],
  };
}

test('history records release chronology and returns to previously shipped versions', () => {
  const releases = [
    release('12.0', '12A7209', '2020-09-17', '3.28.0'),
    release('12.0', '12A8169g', '2020-07-22', '3.32.3'),
    release('12.0', '12A8158a', '2020-06-22', '3.31.1'),
    release('12.0.1', '12A7300', '2020-09-18', '3.31.1'),
  ];
  const history = componentHistory(releases, 'sqlite3', 'Xcode')!;
  assert.deepEqual(
    history.transitions.map(({ version, direction }) => [version, direction]),
    [
      ['3.31.1', 'upgraded'],
      ['3.28.0', 'downgraded'],
      ['3.32.3', 'upgraded'],
      ['3.31.1', 'added'],
    ],
  );
  assert.deepEqual(
    history.changes.map(({ version, direction }) => [version, direction]),
    [
      ['3.32.3', 'upgraded'],
      ['3.31.1', 'upgraded'],
      ['3.28.0', 'added'],
    ],
  );
  assert.equal(history.changes[1].firstReleaseSlug, '12.0-12A8158a');
  assert.equal(history.transitions[1].previousReleaseSlug, '12.0-12A8169g');
  assert.equal(history.latestVersion, '3.31.1');
});

test('maintenance updates follow their own line while new minors inherit the closest prior minor', () => {
  const history = componentHistory(
    [
      release('12.0', '12A1', '2020-01-01', '3.0'),
      release('12.2', '12B2', '2020-02-01', '3.2'),
      release('12.0.1', '12A3', '2020-03-01', '3.1'),
      release('12.3', '12D4', '2020-04-01', '3.3'),
      release('13.0', '13A1', '2020-04-01', '3.2'),
      release('12.3.1', '12D8', '2020-05-01', '3.3'),
    ],
    'sqlite3',
    'macOS',
  )!;
  assert.deepEqual(
    history.transitions.map(({ firstReleaseSlug, previousReleaseSlug }) => [firstReleaseSlug, previousReleaseSlug]),
    [
      ['13.0-13A1', '12.3-12D4'],
      ['12.3-12D4', '12.2-12B2'],
      ['12.0.1-12A3', '12.0-12A1'],
      ['12.2-12B2', '12.0-12A1'],
      ['12.0-12A1', null],
    ],
  );
  assert.equal(history.latestVersion, '3.3');
  assert.equal(componentHistory([], 'missing', 'macOS'), null);
});

test('a new major follows the latest dated release of the nearest lower major, including unchanged releases', () => {
  const history = componentHistory(
    [
      release('12.0', '12A1', '2020-01-01', '3.0'),
      release('12.4', '12D1', '2020-02-01', '3.4'),
      release('12.0.1', '12A2', '2020-03-01', '3.0'),
      release('13.0', '13A1', '2020-04-01', '3.1'),
      release('12.4.1', '12D2', '2020-05-01', '3.5'),
      release('14.0', '14A1', '2020-06-01', '3.1'),
    ],
    'sqlite3',
    'macOS',
  )!;
  const boundary = history.transitions.find((row) => row.firstReleaseSlug === '13.0-13A1')!;
  assert.deepEqual(
    [boundary.previousReleaseSlug, boundary.previousVersion, boundary.direction],
    ['12.0.1-12A2', '3.0', 'upgraded'],
  );
  assert.equal(
    history.transitions.some((row) => row.firstReleaseSlug === '14.0-14A1'),
    false,
  );
  assert.equal(history.transitions.filter((row) => row.direction === 'added').length, 1);
});

test('distinct versions preserve collection order when first appearances share a date', () => {
  const history = componentHistory(
    [release('12.1', '12B2', '2020-01-01', '3.0'), release('12.0', '12A1', '2020-01-01', '3.0')],
    'sqlite3',
    'Xcode',
  )!;
  assert.equal(history.changes[0].firstReleaseSlug, '12.1-12B2');
  assert.equal(history.transitions[0].firstReleaseSlug, '12.0-12A1');
});
