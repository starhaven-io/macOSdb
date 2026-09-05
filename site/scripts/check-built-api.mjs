import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const siteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

for (const [product, expectedProductType] of [
  ['macos', 'macOS'],
  ['xcode', 'Xcode'],
]) {
  const responsePath = path.join(siteRoot, 'dist', 'client', 'api', 'v1', product, 'releases', 'latest.json');
  const response = JSON.parse(fs.readFileSync(responsePath, 'utf8'));
  if (response.productType !== expectedProductType) {
    throw new Error(`${product} latest API response must preserve productType=${expectedProductType}`);
  }
}

console.log('check-built-api: latest release responses preserve their documented product identity.');
