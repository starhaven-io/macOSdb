import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { compareBuilds, compareVersions } from '../src/lib/utils.ts';

interface Vector {
  lhs: string;
  rhs: string;
  expected: 'lt' | 'gt' | 'eq';
}

const vectors: { osVersions: Vector[]; componentVersions: Vector[]; builds: Vector[] } = JSON.parse(
  readFileSync(new URL('../../Tests/macOSdbCoreTests/Fixtures/ordering-vectors.json', import.meta.url), 'utf8'),
);

const directionFor = { lt: 'upgraded', gt: 'downgraded', eq: 'unchanged' } as const;

test('version vectors match compareVersions', () => {
  for (const { lhs, rhs, expected } of [...vectors.osVersions, ...vectors.componentVersions]) {
    assert.equal(compareVersions(lhs, rhs), directionFor[expected], `${lhs} vs ${rhs}`);
  }
});

test('build vectors match compareBuilds', () => {
  for (const { lhs, rhs, expected } of vectors.builds) {
    const result = compareBuilds(lhs, rhs);
    if (expected === 'lt') assert.ok(result < 0, `${lhs} should order before ${rhs}`);
    else if (expected === 'gt') assert.ok(result > 0, `${lhs} should order after ${rhs}`);
    else assert.equal(result, 0, `${lhs} should tie with ${rhs}`);
  }
});
