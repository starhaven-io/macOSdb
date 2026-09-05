import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { deviceNames } from '../src/lib/deviceNames.ts';

test('website device names match the Swift registry', () => {
  const swift = readFileSync(new URL('../../Sources/macOSdbCore/Models/DeviceRegistry.swift', import.meta.url), 'utf8');
  const entries = new Map<string, string>();
  const pattern = /DeviceInfo\(model:\s*"([^"]+)",[\s\S]*?marketingName:\s*"([^"]+)"\)/g;
  for (const match of swift.matchAll(pattern)) entries.set(match[1], match[2]);

  assert.ok(entries.size > 0, 'failed to parse any DeviceRegistry entries');
  assert.deepEqual(Object.fromEntries(entries), deviceNames);
});
