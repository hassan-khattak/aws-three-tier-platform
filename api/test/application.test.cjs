'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../lib/application');
const { DatabaseUnavailableError } = require('../lib/database');

async function serve(t, database, logger) {
  const app = createApp({ database, logger });
  const server = await new Promise((resolve, reject) => {
    const running = app.listen(0, '127.0.0.1', () => resolve(running));
    running.once('error', reject);
  });
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });
  return `http://127.0.0.1:${server.address().port}`;
}

test('HTTP success uses a fresh request UUID and database-supplied time', async (t) => {
  const records = [];
  const url = await serve(t, { readTime: async () => '2026-09-30T12:00:00.000Z' }, (record) => records.push(record));
  const ids = new Set();
  for (let i = 0; i < 2; i++) {
    const response = await fetch(`${url}/api/status?password=never-log-this`, { signal: AbortSignal.timeout(2000) });
    assert.equal(response.status, 200);
    const [body] = await response.json();
    assert.equal(body.time, '2026-09-30T12:00:00.000Z');
    assert.match(body.request_uuid, /^[0-9a-f-]{36}$/);
    assert.equal(response.headers.get('x-request-id'), body.request_uuid);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    ids.add(body.request_uuid);
  }
  assert.equal(ids.size, 2);
  assert.equal(records.length, 2);
  assert.ok(!JSON.stringify(records).includes('never-log-this'));
});

test('dependency errors produce one sanitized 503 response and request log', async (t) => {
  const records = [];
  const url = await serve(t, { readTime: async () => { throw new DatabaseUnavailableError('AUTH_ERROR'); } }, (record) => records.push(record));
  const response = await fetch(`${url}/api/status`, { signal: AbortSignal.timeout(2000) });
  assert.equal(response.status, 503);
  const body = await response.json();
  assert.deepEqual(body.error, { code: 'DATABASE_UNAVAILABLE' });
  assert.equal(records[0].reason, 'AUTH_ERROR');
  assert.equal(records[0].status, 503);
  assert.equal(records[0].request_id, body.request_uuid);
});

test('unknown paths return stable 404 JSON without logging the arbitrary path', async (t) => {
  const records = [];
  const url = await serve(t, { readTime: async () => { throw new Error('Must not query'); } }, (record) => records.push(record));
  const response = await fetch(`${url}/private-value`, { signal: AbortSignal.timeout(2000) });
  assert.equal(response.status, 404);
  assert.deepEqual((await response.json()).error, { code: 'NOT_FOUND' });
  assert.equal(records[0].route, 'unmatched');
  assert.ok(!JSON.stringify(records).includes('private-value'));
});

test('liveness never queries the database; readiness reflects it', async (t) => {
  let healthy = false;
  let reads = 0;
  const database = { readTime: async () => { reads++; if (!healthy) throw new DatabaseUnavailableError('CONNECTION_ERROR'); return '2026-09-30T12:00:00.000Z'; } };
  const url = await serve(t, database, () => {});
  const live = await fetch(`${url}/health/live`);
  assert.equal(live.status, 200);
  assert.deepEqual(await live.json(), { status: 'ok' });
  assert.equal(reads, 0);
  const down = await fetch(`${url}/health/ready`);
  assert.equal(down.status, 503);
  assert.deepEqual(await down.json(), { status: 'unavailable' });
  healthy = true;
  const up = await fetch(`${url}/health/ready`);
  assert.equal(up.status, 200);
  assert.deepEqual(await up.json(), { status: 'ready' });
  assert.equal(reads, 2);
});

test('while draining, readiness is 503 without a query and responses close the connection', async (t) => {
  let reads = 0;
  const app = createApp({ database: { readTime: async () => { reads++; return '2026-09-30T12:00:00.000Z'; } }, logger: () => {} });
  const server = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  t.after(async () => { server.closeAllConnections(); await new Promise((r) => server.close(r)); });
  app.locals.draining = true;
  const url = `http://127.0.0.1:${server.address().port}`;
  const ready = await fetch(`${url}/health/ready`);
  assert.equal(ready.status, 503);
  assert.deepEqual(await ready.json(), { status: 'draining' });
  assert.equal(ready.headers.get('connection'), 'close');
  assert.equal(reads, 0);
  assert.equal((await fetch(`${url}/health/live`)).status, 200);
});
