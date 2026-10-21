import assert from 'node:assert/strict';
import test from 'node:test';
import { buildApp } from '../dist/app.js';

test('GET /healthz returns ok', async (t) => {
  const app = buildApp();
  t.after(() => app.close());
  const response = await app.inject({ method: 'GET', url: '/healthz' });
  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.json(), { ok: true });
});
