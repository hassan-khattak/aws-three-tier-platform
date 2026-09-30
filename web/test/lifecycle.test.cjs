'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const test = require('node:test');
const { performance } = require('node:perf_hooks');
const { setTimeout: delay } = require('node:timers/promises');
const { createApp } = require('../lib/application');
const { spawnService } = require('../../tests/helpers/service-process.cjs');
const { listen, fakeApi, json, VALID } = require('../../tests/helpers/fake-api.cjs');

function refused(port) {
  return new Promise((resolve) => {
    const socket = net.connect(port, '127.0.0.1');
    socket.once('connect', () => { socket.destroy(); resolve(false); });
    socket.once('error', (error) => resolve(error.code === 'ECONNREFUSED'));
  });
}

// Each service image carries its own copy; the API test suite covers it.
test('the web lifecycle module is identical to the tested API module', () => {
  const read = (service) => fs.readFileSync(path.join(__dirname, `../../${service}/lib/lifecycle.js`), 'utf8');
  assert.equal(read('web'), read('api'));
});

test('liveness never calls the API; readiness reflects it and turns 503 while draining', async (t) => {
  let healthy = false;
  let calls = 0;
  const upstream = { readStatus: async () => { calls++; if (!healthy) throw Object.assign(new Error('x'), { reason: 'UPSTREAM_UNREACHABLE' }); return {}; } };
  const app = createApp({ upstream, logger: () => {} });
  const url = await listen(t, http.createServer(app));
  assert.equal((await fetch(`${url}/health/live`)).status, 200);
  assert.equal(calls, 0);
  assert.equal((await fetch(`${url}/health/ready`)).status, 503);
  healthy = true;
  const ready = await fetch(`${url}/health/ready`);
  assert.equal(ready.status, 200);
  assert.deepEqual(await ready.json(), { status: 'ready' });
  app.locals.draining = true;
  const draining = await fetch(`${url}/health/ready`);
  assert.equal(draining.status, 503);
  assert.deepEqual(await draining.json(), { status: 'draining' });
  assert.equal(calls, 2);
});

test('the launcher waits for the API before listening, then serves', { timeout: 20000 }, async (t) => {
  // Reserve a port for the API, but do not answer on it yet.
  const reserved = net.createServer();
  await new Promise((resolve) => reserved.listen(0, '127.0.0.1', resolve));
  const apiPort = reserved.address().port;
  await new Promise((resolve) => reserved.close(resolve));
  const web = spawnService('web', { API_HOST: `http://127.0.0.1:${apiPort}` });
  t.after(() => web.stop());
  await web.event('startup_waiting', 8000);
  await delay(1500);
  assert.ok(!web.records.some((r) => r.event === 'server_listening'));
  const api = http.createServer((req, res) => json(res, 200, [VALID]));
  await new Promise((resolve) => api.listen(apiPort, '127.0.0.1', resolve));
  t.after(async () => { api.closeAllConnections(); await new Promise((r) => api.close(r)); });
  await web.event('server_listening', 5000);
  const page = await fetch(web.url());
  assert.equal(page.status, 200);
  assert.ok((await page.text()).includes(VALID.request_uuid));
});

test('readiness follows the API while liveness stays 200, without restarting web', { timeout: 20000 }, async (t) => {
  let up = true;
  const api = await fakeApi(t, (req, res) => (up ? json(res, 200, [VALID]) : json(res, 503, { error: { code: 'DATABASE_UNAVAILABLE' } })));
  const web = spawnService('web', { API_HOST: api.url });
  t.after(() => web.stop());
  await web.event('server_listening', 8000);
  const pid = web.child.pid;
  assert.equal((await fetch(`${web.url()}/health/ready`)).status, 200);
  up = false;
  assert.equal((await fetch(`${web.url()}/health/ready`)).status, 503);
  assert.equal((await fetch(`${web.url()}/health/live`)).status, 200);
  up = true;
  assert.equal((await fetch(`${web.url()}/health/ready`)).status, 200);
  assert.equal(web.child.pid, pid);
  assert.equal(web.child.exitCode, null);
});

test('SIGTERM completes an in-flight page, refuses new connections and exits 0 within 20 s', { timeout: 30000 }, async (t) => {
  let hold = false;
  let arrived;
  const reached = new Promise((resolve) => { arrived = resolve; });
  const api = await fakeApi(t, (req, res) => {
    if (!hold) return json(res, 200, [VALID]);
    arrived();
    setTimeout(() => json(res, 200, [VALID]), 1500);
  });
  const web = spawnService('web', { API_HOST: api.url });
  t.after(() => web.stop());
  await web.event('server_listening', 8000);
  const port = new URL(web.url()).port;
  hold = true;
  const pending = fetch(web.url());
  await reached;
  const started = performance.now();
  web.child.kill('SIGTERM');
  await web.event('shutdown_started', 2000);
  assert.equal(await refused(port), true);
  const page = await pending;
  assert.equal(page.status, 200);
  assert.ok((await page.text()).includes(VALID.request_uuid));
  const { code } = await web.exited;
  const elapsed = performance.now() - started;
  assert.equal(code, 0);
  assert.ok(elapsed >= 1000 && elapsed < 20000, `elapsed ${elapsed}`);
  assert.ok(web.records.some((r) => r.event === 'shutdown_complete'));
});
