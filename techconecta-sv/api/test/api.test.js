import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';

process.env.SUPABASE_URL = 'https://example.supabase.co';
process.env.SUPABASE_ANON_KEY = 'test-key';
process.env.NODE_ENV = 'test';

const { app } = await import('../src/index.js');
let server;
let baseUrl;

before(() => new Promise((resolve) => {
  server = app.listen(0, () => {
    baseUrl = `http://127.0.0.1:${server.address().port}`;
    resolve();
  });
}));

after(() => new Promise((resolve, reject) => {
  server.close((error) => (error ? reject(error) : resolve()));
}));

test('GET /health reports the API is ready', async () => {
  const response = await fetch(`${baseUrl}/health`);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).status, 'ok');
});

test('protected routes reject missing credentials', async () => {
  const response = await fetch(`${baseUrl}/me`);
  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: 'Token requerido' });
});

test('profile photo upload requires authentication', async () => {
  const response = await fetch(`${baseUrl}/tecnicos/me/foto`, {
    method: 'POST',
  });
  assert.equal(response.status, 401);
});
