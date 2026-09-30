'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { performance } = require('node:perf_hooks');
const { createUpstream, BUDGETS } = require('../lib/upstream');
const { fakeApi, json, VALID } = require('../../tests/helpers/fake-api.cjs');

const budgets = { request: 300, maxBodyBytes: 1024 };
function client(url, extra = {}) {
  return createUpstream({ statusUrl: `${url}/api/status`, budgets, ...extra });
}

test('the approved total upstream budget is 5 s', () => {
  assert.equal(BUDGETS.request, 5000);
});

test('a valid API response yields its time and UUID', async (t) => {
  const api = await fakeApi(t, (req, res) => json(res, 200, [VALID]));
  assert.deepEqual(await client(api.url).readStatus(), { time: VALID.time, requestUuid: VALID.request_uuid });
  assert.equal(api.requests[0].url, '/api/status');
});

test('malformed responses are rejected as 502 before any field is used', async (t) => {
  const cases = [
    ['empty array', (res) => json(res, 200, [])],
    ['object instead of array', (res) => json(res, 200, VALID)],
    ['array of null', (res) => json(res, 200, [null])],
    ['not JSON', (res) => json(res, 200, '<html>')],
    ['wrong content type', (res) => { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end(JSON.stringify([VALID])); }],
    ['missing time', (res) => json(res, 200, [{ request_uuid: VALID.request_uuid }])],
    ['unparseable time', (res) => json(res, 200, [{ ...VALID, time: 'yesterday-ish' }])],
    ['numeric time', (res) => json(res, 200, [{ ...VALID, time: 12 }])],
    ['missing UUID', (res) => json(res, 200, [{ time: VALID.time }])],
    ['non-UUID', (res) => json(res, 200, [{ ...VALID, request_uuid: '<script>' }])],
    ['oversized body', (res) => json(res, 200, [{ ...VALID, pad: 'x'.repeat(4096) }])],
    ['oversized chunked body', (res) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.write('['); res.end('"x",'.repeat(1000) + '1]'); }],
    ['unexpected status 500', (res) => json(res, 500, { error: 'boom' })],
    ['not found', (res) => json(res, 404, { error: { code: 'NOT_FOUND' } })],
  ];
  for (const [name, respond] of cases) {
    const api = await fakeApi(t, (req, res) => respond(res));
    await assert.rejects(client(api.url).readStatus(), (error) => {
      assert.equal(error.status, 502, name);
      return true;
    });
  }
});

test('redirects are not followed', async (t) => {
  const target = await fakeApi(t, (req, res) => json(res, 200, [VALID]));
  const api = await fakeApi(t, (req, res) => { res.writeHead(302, { Location: `${target.url}/api/status` }); res.end(); });
  await assert.rejects(client(api.url).readStatus(), { status: 502, reason: 'UNEXPECTED_STATUS' });
  assert.equal(target.requests.length, 0);
});

test('API-reported unavailability and an unreachable API map to 503', async (t) => {
  const api = await fakeApi(t, (req, res) => json(res, 503, { error: { code: 'DATABASE_UNAVAILABLE' } }));
  await assert.rejects(client(api.url).readStatus(), { status: 503, reason: 'UPSTREAM_UNAVAILABLE' });
  await assert.rejects(client('http://127.0.0.1:9').readStatus(), { status: 503, reason: 'UPSTREAM_UNREACHABLE' });
});

test('no response headers, or a stalled body, ends at the deadline and closes the upstream socket', async (t) => {
  for (const [name, handler] of [
    ['no headers', () => {}],
    ['stalled body', (req, res) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.write('[{"time":'); }],
  ]) {
    let closed;
    const upstreamClosed = new Promise((resolve) => { closed = resolve; });
    const api = await fakeApi(t, (req, res) => { req.socket.once('close', closed); handler(req, res); });
    const started = performance.now();
    await assert.rejects(client(api.url).readStatus(), { status: 503, reason: 'UPSTREAM_TIMEOUT' });
    const elapsed = performance.now() - started;
    assert.ok(elapsed >= 280 && elapsed < 600, `${name}: ${elapsed}`);
    await upstreamClosed;
  }
});

test('a caller abort cancels the in-flight upstream request', async (t) => {
  let closed;
  const upstreamClosed = new Promise((resolve) => { closed = resolve; });
  let started;
  const requested = new Promise((resolve) => { started = resolve; });
  const api = await fakeApi(t, (req) => { req.socket.once('close', closed); started(); });
  const controller = new AbortController();
  const pending = client(api.url, { budgets: { ...budgets, request: 5000 } }).readStatus({ signal: controller.signal });
  await requested;
  controller.abort();
  await assert.rejects(pending, { status: 503, reason: 'CLIENT_ABORTED' });
  await upstreamClosed;
});
