'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const http = require('node:http');
const { performance } = require('node:perf_hooks');
const { createApp } = require('../lib/application');
const { createUpstream } = require('../lib/upstream');
const startService = require('../../tests/helpers/start-service.cjs');
const { listen, fakeApi, json, VALID } = require('../../tests/helpers/fake-api.cjs');

async function serve(t, upstream, logger) {
  return listen(t, http.createServer(createApp({ upstream, logger })));
}
function get(url) {
  return fetch(url, { signal: AbortSignal.timeout(7000) });
}
// No response may reveal internal addresses, raw errors or stack traces.
function assertSanitized(html, ...secrets) {
  for (const secret of ['127.0.0.1', 'Error:', '    at ', ...secrets]) assert.ok(!html.includes(secret), secret);
}

test('success renders the API time and UUID through the existing view', async (t) => {
  const records = [];
  const api = await fakeApi(t, (req, res) => json(res, 200, [VALID]));
  const url = await serve(t, createUpstream({ statusUrl: `${api.url}/api/status` }), (r) => records.push(r));
  const response = await get(`${url}/?secret=never-log-this`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.match(response.headers.get('x-request-id'), /^[0-9a-f-]{36}$/);
  const html = await response.text();
  assert.ok(html.includes(`Welcome, it's ${VALID.time}`));
  assert.ok(html.includes(VALID.request_uuid));
  assert.ok(html.includes('/images/nyan.gif'));
  assert.equal(records.length, 1);
  assert.equal(records[0].route, '/');
  assert.equal(records[0].status, 200);
  assert.ok(!JSON.stringify(records).includes('never-log-this'));
});

test('upstream failures render one sanitized error page with the mapped status', async (t) => {
  for (const [name, respond, status] of [
    ['malformed body', (res) => json(res, 200, [{ time: 'bad', request_uuid: VALID.request_uuid }]), 502],
    ['empty array', (res) => json(res, 200, []), 502],
    ['non-200', (res) => json(res, 500, { stack: 'Error: private detail' }), 502],
    ['API unavailable', (res) => json(res, 503, { error: { code: 'DATABASE_UNAVAILABLE' } }), 503],
  ]) {
    const records = [];
    const api = await fakeApi(t, (req, res) => respond(res));
    const url = await serve(t, createUpstream({ statusUrl: `${api.url}/api/status` }), (r) => records.push(r));
    const response = await get(url);
    assert.equal(response.status, status, name);
    assert.match(response.headers.get('content-type'), /text\/html/);
    const html = await response.text();
    assert.ok(html.includes(status === 502 ? 'Bad Gateway' : 'Service Unavailable'), name);
    assertSanitized(html, 'private detail', String(new URL(api.url).port));
    assert.equal(records.length, 1, name);
    assert.equal(records[0].status, status);
    assert.equal(records[0].level, 'error');
    assert.ok(records[0].reason);
  }
});

test('an absent API returns 503 without revealing its address', async (t) => {
  const url = await serve(t, createUpstream({ statusUrl: 'http://127.0.0.1:9/api/status' }), () => {});
  const response = await get(url);
  assert.equal(response.status, 503);
  assertSanitized(await response.text(), ':9/');
});

test('unknown routes render the error template with 404 and never query the API', async (t) => {
  const records = [];
  const url = await serve(t, { readStatus: async () => { throw new Error('must not be called'); } }, (r) => records.push(r));
  const response = await get(`${url}/private-path`);
  assert.equal(response.status, 404);
  const html = await response.text();
  assert.ok(html.includes('Not Found'));
  assertSanitized(html, 'private-path');
  assert.equal(records[0].route, 'unmatched');
  assert.ok(!JSON.stringify(records).includes('private-path'));
});

test('static assets are served cacheable for 5 minutes; pages are never cached', async (t) => {
  const api = await fakeApi(t, (req, res) => json(res, 200, [VALID]));
  const url = await serve(t, createUpstream({ statusUrl: `${api.url}/api/status` }), () => {});
  for (const asset of ['/images/nyan.gif', '/stylesheets/style.css']) {
    const response = await get(`${url}${asset}`);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'public, max-age=300');
    await response.arrayBuffer();
  }
  const page = await get(`${url}/`);
  assert.equal(page.headers.get('cache-control'), 'no-store');
});

test('a browser disconnect aborts the upstream request', async (t) => {
  let closed;
  const upstreamClosed = new Promise((resolve) => { closed = resolve; });
  let requested;
  const reached = new Promise((resolve) => { requested = resolve; });
  const api = await fakeApi(t, (req) => { req.socket.once('close', closed); requested(); });
  const records = [];
  const url = await serve(t, createUpstream({ statusUrl: `${api.url}/api/status` }), (r) => records.push(r));
  const controller = new AbortController();
  const pending = fetch(url, { signal: controller.signal }).catch(() => {});
  await reached;
  controller.abort();
  await pending;
  await upstreamClosed;
  assert.ok(records.some((r) => r.event === 'request_aborted'));
});

test('the production launcher bounds a hung API to the 5 s budget', { timeout: 15000 }, async (t) => {
  // Answer the admission check, then hang every later request.
  let calls = 0;
  const api = await fakeApi(t, (req, res) => { if (++calls === 1) json(res, 200, [VALID]); });
  const url = await startService(t, 'web', { API_HOST: api.url });
  const started = performance.now();
  const response = await get(url);
  const elapsed = performance.now() - started;
  assert.equal(response.status, 503);
  assert.ok(elapsed >= 4900 && elapsed < 5800, `elapsed ${elapsed}`);
  assertSanitized(await response.text());
});
