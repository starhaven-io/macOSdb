import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  loadReleaseDetails,
  readReleaseDetail,
  resolveReleaseFile,
  type ReleasePointer,
} from '../src/lib/releaseFiles.ts';

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'macosdb-release-files-'));
  const productDir = path.join(root, 'macos');
  const releaseDir = path.join(productDir, 'releases', '15');
  fs.mkdirSync(releaseDir, { recursive: true });
  const entry: ReleasePointer = {
    productType: 'macOS',
    osVersion: '15.0',
    buildNumber: '24A335',
    dataFile: 'releases/15/macOS-15.0-24A335.json',
  };
  const detail = { ...entry, productType: 'macOS' };
  fs.writeFileSync(path.join(releaseDir, 'macOS-15.0-24A335.json'), JSON.stringify(detail));
  fs.writeFileSync(path.join(productDir, 'releases.json'), JSON.stringify([entry]));
  return { root, entry };
}

test('canonical release pointers load and preserve the index identity', () => {
  const { root, entry } = fixture();
  try {
    assert.match(resolveReleaseFile(root, 'macos', 'macOS', entry), /macOS-15\.0-24A335\.json$/);
    assert.deepEqual(loadReleaseDetails(root, 'macos', 'macOS')[0].id, '15.0-24A335');
  } finally {
    fs.rmSync(root, { recursive: true });
  }
});

test('non-canonical and traversing release pointers are rejected', () => {
  const { root, entry } = fixture();
  try {
    for (const dataFile of ['releases/15/macOS-15.1-24B83.json', '../outside.json', '/tmp/outside.json']) {
      assert.throws(() => resolveReleaseFile(root, 'macos', 'macOS', { ...entry, dataFile }));
    }
  } finally {
    fs.rmSync(root, { recursive: true });
  }
});

test('a canonical-looking symlink cannot escape the product directory', () => {
  const { root, entry } = fixture();
  try {
    const detailPath = path.join(root, 'macos', entry.dataFile);
    const outside = path.join(root, 'outside.json');
    fs.writeFileSync(outside, '{}');
    fs.rmSync(detailPath);
    fs.symlinkSync(outside, detailPath);
    assert.throws(() => resolveReleaseFile(root, 'macos', 'macOS', entry), /inside the product directory/);
  } finally {
    fs.rmSync(root, { recursive: true });
  }
});

test('a product-directory symlink cannot escape the selected data root', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'macosdb-release-root-'));
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'macosdb-release-outside-'));
  try {
    fs.mkdirSync(path.join(outside, 'releases'), { recursive: true });
    fs.writeFileSync(path.join(outside, 'releases.json'), '[]');
    fs.symlinkSync(outside, path.join(root, 'macos'));
    assert.throws(() => loadReleaseDetails(root, 'macos', 'macOS'), /escapes the data root/);
  } finally {
    fs.rmSync(root, { recursive: true });
    fs.rmSync(outside, { recursive: true });
  }
});

test('detail identity and product are bound to the index entry', () => {
  const { root, entry } = fixture();
  const detailPath = path.join(root, 'macos', entry.dataFile);
  try {
    for (const mutation of [{ osVersion: '15.1' }, { buildNumber: '24B83' }, { productType: 'Xcode' }]) {
      fs.writeFileSync(detailPath, JSON.stringify({ ...entry, productType: 'macOS', ...mutation }));
      assert.throws(() => readReleaseDetail(root, 'macos', 'macOS', entry));
    }
  } finally {
    fs.rmSync(root, { recursive: true });
  }
});

test('index entries require canonical identities, products, and one-to-one pointers', () => {
  const { root, entry } = fixture();
  const indexPath = path.join(root, 'macos', 'releases.json');
  try {
    for (const entries of [[{ ...entry, productType: 'Xcode' }], [{ ...entry, osVersion: '../15' }], [entry, entry]]) {
      fs.writeFileSync(indexPath, JSON.stringify(entries));
      assert.throws(() => loadReleaseDetails(root, 'macos', 'macOS'));
    }
  } finally {
    fs.rmSync(root, { recursive: true });
  }
});

test('index and detail reads reject escapes and oversized files', () => {
  const { root, entry } = fixture();
  const productDir = path.join(root, 'macos');
  const indexPath = path.join(productDir, 'releases.json');
  const detailPath = path.join(productDir, entry.dataFile);
  try {
    const outside = path.join(root, 'outside-index.json');
    fs.writeFileSync(outside, JSON.stringify([entry]));
    fs.rmSync(indexPath);
    fs.symlinkSync(outside, indexPath);
    assert.throws(() => loadReleaseDetails(root, 'macos', 'macOS'), /inside the product directory/);

    fs.rmSync(indexPath);
    fs.writeFileSync(indexPath, Buffer.alloc(4 * 1024 * 1024 + 1));
    assert.throws(() => loadReleaseDetails(root, 'macos', 'macOS'), /size limit/);

    fs.writeFileSync(indexPath, JSON.stringify([entry]));
    fs.writeFileSync(detailPath, Buffer.alloc(16 * 1024 * 1024 + 1));
    assert.throws(() => loadReleaseDetails(root, 'macos', 'macOS'), /size limit/);
  } finally {
    fs.rmSync(root, { recursive: true });
  }
});
