import assert from 'node:assert/strict';
import { test } from 'node:test';
import { hasUnknownComparisonRelease } from '../src/lib/comparisonSelection.ts';

test('empty and partially selected forms stay usable; every supplied release must exist', () => {
  const ids = new Set(['15.0-24A335', '15.1-24B83']);
  for (const query of ['', '?from=&to=', '?from=15.0-24A335', '?from=15.0-24A335&to=15.1-24B83']) {
    assert.equal(hasUnknownComparisonRelease(new URL(`https://example.test/macos/compare/${query}`), ids), false);
  }
  for (const query of ['?from=missing', '?to=missing', '?from=15.0-24A335&to=missing']) {
    assert.equal(hasUnknownComparisonRelease(new URL(`https://example.test/macos/compare/${query}`), ids), true);
  }
});
