import fs from 'node:fs';
import path from 'node:path';

export type ProductKey = 'macos' | 'xcode';
export type ProductPrefix = 'macOS' | 'Xcode';

export interface ReleasePointer extends Record<string, unknown> {
  productType: 'macOS' | 'Xcode';
  osVersion: string;
  buildNumber: string;
  dataFile: string;
}

export type LoadedReleaseDetail = Record<string, unknown> & { id: string };

const MAX_INDEX_BYTES = 4 * 1024 * 1024;
const MAX_RELEASE_BYTES = 16 * 1024 * 1024;

function isInside(parent: string, child: string): boolean {
  const relative = path.relative(parent, child);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function resolveProductDirectory(dataRoot: string, product: ProductKey): string {
  const resolvedRoot = fs.realpathSync(path.resolve(dataRoot));
  const productDir = fs.realpathSync(path.resolve(resolvedRoot, product));
  if (productDir === resolvedRoot || !isInside(resolvedRoot, productDir)) {
    throw new Error(`${product}: product directory escapes the data root`);
  }
  return productDir;
}

function resolveBoundedFile(parent: string, candidate: string, maxBytes: number, label: string): string {
  const resolved = fs.realpathSync(candidate);
  const metadata = fs.statSync(resolved);
  if (!isInside(parent, resolved) || !metadata.isFile()) {
    throw new Error(`${label} is not a regular file inside the product directory`);
  }
  if (metadata.size > maxBytes) {
    throw new Error(`${label} exceeds the ${maxBytes}-byte size limit`);
  }
  return resolved;
}

function readBoundedFile(parent: string, candidate: string, maxBytes: number, label: string): string {
  const resolved = fs.realpathSync(candidate);
  if (!isInside(parent, resolved)) {
    throw new Error(`${label} is not a regular file inside the product directory`);
  }

  const noFollow = fs.constants.O_NOFOLLOW ?? 0;
  const descriptor = fs.openSync(resolved, fs.constants.O_RDONLY | noFollow);
  try {
    const metadata = fs.fstatSync(descriptor);
    if (!metadata.isFile()) {
      throw new Error(`${label} is not a regular file inside the product directory`);
    }
    if (metadata.size > maxBytes) {
      throw new Error(`${label} exceeds the ${maxBytes}-byte size limit`);
    }

    const chunks: Buffer[] = [];
    let bytesRead = 0;
    while (bytesRead <= maxBytes) {
      const chunk = Buffer.allocUnsafe(Math.min(64 * 1024, maxBytes + 1 - bytesRead));
      const count = fs.readSync(descriptor, chunk, 0, chunk.length, null);
      if (count === 0) break;
      bytesRead += count;
      chunks.push(chunk.subarray(0, count));
    }
    if (bytesRead > maxBytes) {
      throw new Error(`${label} exceeds the ${maxBytes}-byte size limit`);
    }
    return Buffer.concat(chunks, bytesRead).toString('utf8');
  } finally {
    fs.closeSync(descriptor);
  }
}

export function expectedDataFile(entry: Pick<ReleasePointer, 'osVersion' | 'buildNumber'>, prefix: ProductPrefix) {
  if (!/^\d+\.\d+(?:\.\d+)?$/.test(entry.osVersion) || !/^\d+[A-Z]\d+[a-z]?$/.test(entry.buildNumber)) {
    throw new Error(`invalid release identity ${entry.osVersion}-${entry.buildNumber}`);
  }
  const major = entry.osVersion.split('.')[0];
  return `releases/${major}/${prefix}-${entry.osVersion}-${entry.buildNumber}.json`;
}

export function resolveReleaseFile(
  dataRoot: string,
  product: ProductKey,
  prefix: ProductPrefix,
  entry: ReleasePointer,
): string {
  const productDir = resolveProductDirectory(dataRoot, product);
  const expected = expectedDataFile(entry, prefix);
  if (entry.dataFile !== expected) {
    throw new Error(`${product} ${entry.buildNumber}: dataFile must be ${expected}`);
  }

  return resolveBoundedFile(
    productDir,
    path.resolve(productDir, expected),
    MAX_RELEASE_BYTES,
    `${product} ${entry.buildNumber}: dataFile`,
  );
}

export function readReleaseIndex(
  dataRoot: string,
  product: ProductKey,
  prefix: ProductPrefix,
): { entries: ReleasePointer[]; source: string } {
  const productDir = resolveProductDirectory(dataRoot, product);
  const source = readBoundedFile(
    productDir,
    path.join(productDir, 'releases.json'),
    MAX_INDEX_BYTES,
    `${product}: releases.json`,
  );
  const parsed = JSON.parse(source) as unknown;
  if (!Array.isArray(parsed)) throw new Error(`${product}: releases.json must contain an array`);

  const expectedProductType = product === 'macos' ? 'macOS' : 'Xcode';
  const identities = new Set<string>();
  const dataFiles = new Set<string>();
  const entries = parsed.map((value, index) => {
    if (
      typeof value !== 'object' ||
      value === null ||
      value.productType !== expectedProductType ||
      typeof value.osVersion !== 'string' ||
      typeof value.buildNumber !== 'string' ||
      typeof value.dataFile !== 'string'
    ) {
      throw new Error(`${product}: releases.json entry ${index} has an invalid identity or dataFile`);
    }
    const entry = value as ReleasePointer;
    resolveReleaseFile(dataRoot, product, prefix, entry);
    const identity = `${entry.osVersion}\0${entry.buildNumber}`;
    if (identities.has(identity) || dataFiles.has(entry.dataFile)) {
      throw new Error(`${product}: releases.json entry ${index} duplicates an identity or dataFile`);
    }
    identities.add(identity);
    dataFiles.add(entry.dataFile);
    return entry;
  });
  return { entries, source };
}

export function loadReleaseIndex(dataRoot: string, product: ProductKey, prefix: ProductPrefix): ReleasePointer[] {
  return readReleaseIndex(dataRoot, product, prefix).entries;
}

export function loadReleaseDetails(dataRoot: string, product: ProductKey, prefix: ProductPrefix) {
  return loadReleaseIndex(dataRoot, product, prefix).map(
    (entry) => readReleaseDetail(dataRoot, product, prefix, entry).data,
  );
}

export function readReleaseDetail(
  dataRoot: string,
  product: ProductKey,
  prefix: ProductPrefix,
  entry: ReleasePointer,
): { data: LoadedReleaseDetail; source: string } {
  const productDir = resolveProductDirectory(dataRoot, product);
  const expected = expectedDataFile(entry, prefix);
  if (entry.dataFile !== expected) {
    throw new Error(`${product} ${entry.buildNumber}: dataFile must be ${expected}`);
  }
  const source = readBoundedFile(
    productDir,
    path.resolve(productDir, expected),
    MAX_RELEASE_BYTES,
    `${product} ${entry.buildNumber}: dataFile`,
  );
  const parsed = JSON.parse(source) as unknown;
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error(`${product} ${entry.buildNumber}: detail must contain an object`);
  }

  const data = parsed as Record<string, unknown>;
  if (data.osVersion !== entry.osVersion || data.buildNumber !== entry.buildNumber) {
    throw new Error(`${product} ${entry.buildNumber}: detail identity does not match its index entry`);
  }
  const expectedProductType = product === 'macos' ? 'macOS' : 'Xcode';
  if (data.productType !== expectedProductType) {
    throw new Error(`${product} ${entry.buildNumber}: detail productType must be ${expectedProductType}`);
  }

  const loaded: LoadedReleaseDetail = { ...data, id: `${entry.osVersion}-${entry.buildNumber}` };
  return { data: loaded, source };
}
