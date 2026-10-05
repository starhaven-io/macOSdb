import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { macosReleaseDetailSchema, xcodeReleaseDetailSchema } from '../src/lib/releaseSchemas.ts';

const macos = JSON.parse(readFileSync('../data/macos/releases/15/macOS-15.0-24A335.json', 'utf8'));
const xcode = JSON.parse(readFileSync('../data/xcode/releases/16/Xcode-16.0-16A242d.json', 'utf8'));
for (const [product, schema, release] of [
  ['macos', macosReleaseDetailSchema, macos],
  ['xcode', xcodeReleaseDetailSchema, xcode],
] as const) {
  test(`${product} schema rejects empty collections and cross-product sources`, () => {
    const valid = { ...release, id: 'fixture' };
    assert.equal(schema.safeParse(valid).success, true);
    assert.equal(schema.safeParse({ ...valid, components: [] }).success, false);
    assert.equal(
      schema.safeParse({
        ...valid,
        components: [{ ...valid.components[0], source: product === 'macos' ? 'sdk' : 'dyldCache' }],
      }).success,
      false,
    );
    for (const field of ['betaNumber', 'betaRevision', 'rcNumber']) {
      assert.equal(schema.safeParse({ ...valid, [field]: null }).success, false);
    }
  });
}
test('macOS kernels and Xcode SDK versions must be complete and unique', () => {
  assert.equal(macosReleaseDetailSchema.safeParse({ ...macos, id: 'fixture', kernels: [] }).success, false);
  assert.equal(
    xcodeReleaseDetailSchema.safeParse({ ...xcode, id: 'fixture', sdks: [xcode.sdks[0], xcode.sdks[0]] }).success,
    false,
  );
});

test('macOS device identifiers cannot be empty', () => {
  assert.equal(
    macosReleaseDetailSchema.safeParse({
      ...macos,
      id: 'fixture',
      kernels: [{ ...macos.kernels[0], devices: ['Mac14,2', ''] }],
    }).success,
    false,
  );
});
