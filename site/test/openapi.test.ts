import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

test('OpenAPI document covers every public route family', () => {
  const document = JSON.parse(readFileSync(new URL('../public/openapi.json', import.meta.url), 'utf8'));
  assert.equal(document.openapi, '3.1.0');
  assert.deepEqual(Object.keys(document.paths).sort(), [
    '/api/v1/{product}/compare/{from}/{to}.json',
    '/api/v1/{product}/components.json',
    '/api/v1/{product}/components/{name}.json',
    '/api/v1/{product}/releases.json',
    '/api/v1/{product}/releases/latest.json',
    '/api/v1/{product}/releases/{major}/{file}.json',
  ]);
});

test('OpenAPI document distinguishes static HTML misses from JSON API misses', () => {
  const document = JSON.parse(readFileSync(new URL('../public/openapi.json', import.meta.url), 'utf8'));
  const releaseResponses = document.paths['/api/v1/{product}/releases/{major}/{file}.json'].get.responses;
  const latestResponses = document.paths['/api/v1/{product}/releases/latest.json'].get.responses;
  const componentResponses = document.paths['/api/v1/{product}/components/{name}.json'].get.responses;
  const compareResponses = document.paths['/api/v1/{product}/compare/{from}/{to}.json'].get.responses;

  assert.equal(releaseResponses['404'].$ref, '#/components/responses/StaticNotFound');
  assert.equal(componentResponses['404'].$ref, '#/components/responses/StaticNotFound');
  assert.equal(latestResponses['404'], undefined);
  assert.equal(compareResponses['404'].$ref, '#/components/responses/NotFound');
  assert.ok(document.components.responses.StaticNotFound.content['text/html']);
  assert.ok(document.components.responses.NotFound.content['application/json']);
});
