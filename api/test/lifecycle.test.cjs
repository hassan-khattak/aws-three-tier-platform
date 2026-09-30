'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const net = require('node:net');
const test = require('node:test');
const { once } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');
const { performance } = require('node:perf_hooks');
const { createLifecycle, BUDGETS } = require('../lib/lifecycle');

const budgets = { admission: 400, retry: 50, shutdown: 1000 };
function harness({ check = async () => {}, close = async () => {}, handler = (req, res) => res.end('ok'), budget = budgets } = {}) {
  const app = { locals: {} };
  const server = http.createServer((req, res) => {
    if (app.locals.draining) res.setHeader('Connection', 'close');
    handler(req, res);
  });
  const exits = [];
  let exited;
  const exitedPromise = new Promise((resolve) => { exited = resolve; });
  const records = [];
  const lifecycle = createLifecycle({
    app, server, check, close, budgets: budget,
    logger: (record) => records.push(record),
    exit: (code) => { exits.push(code); exited(code); },
  });
  return { app, server, lifecycle, exits, exited: exitedPromise, records };
}
function refused(port) {
  return new Promise((resolve) => {
    const socket = net.connect(port, '127.0.0.1');
    socket.once('connect', () => { socket.destroy(); resolve(false); });
    socket.once('error', (error) => resolve(error.code === 'ECONNREFUSED'));
  });
}

test('approved budgets: 60 s admission, 20 s shutdown', () => {
  assert.equal(BUDGETS.admission, 60000);
  assert.equal(BUDGETS.shutdown, 20000);
});

test('the server listens only after a dependency check succeeds', async (t) => {
  let calls = 0;
  const h = harness({ check: async () => { if (++calls < 3) throw Object.assign(new Error('x'), { reason: 'CONNECTION_ERROR' }); } });
  t.after(() => h.server.close());
  await h.lifecycle.start(0);
  await once(h.server, 'listening');
  assert.equal(calls, 3);
  assert.equal(h.records.filter((r) => r.event === 'startup_waiting').length, 2);
  assert.equal(h.records[0].reason, 'CONNECTION_ERROR');
  assert.equal(h.lifecycle.state(), 'serving');
});

test('an exhausted admission budget exits 1 without listening and releases resources', async () => {
  let closed = 0;
  const h = harness({ check: async () => { throw new Error('down'); }, close: async () => { closed++; } });
  const started = performance.now();
  await h.lifecycle.start(0);
  const elapsed = performance.now() - started;
  assert.deepEqual(h.exits, [1]);
  assert.equal(h.server.listening, false);
  assert.equal(closed, 1);
  assert.ok(elapsed >= 380 && elapsed < 700, `elapsed ${elapsed}`);
  assert.ok(h.records.some((r) => r.event === 'startup_failed' && r.code === 'DEPENDENCY_UNAVAILABLE'));
});

test('a hung dependency check is cut off at the admission deadline', async () => {
  const h = harness({ check: ({ signal }) => new Promise((_, reject) => signal.addEventListener('abort', () => reject(new Error('aborted')))) });
  const started = performance.now();
  await h.lifecycle.start(0);
  assert.deepEqual(h.exits, [1]);
  assert.ok(performance.now() - started < 700);
});

test('a signal during admission exits 0 without ever listening', async () => {
  let closed = 0;
  const h = harness({ check: async () => { throw new Error('down'); }, close: async () => { closed++; }, budget: { ...budgets, admission: 5000 } });
  const starting = h.lifecycle.start(0);
  await delay(80);
  await h.lifecycle.shutdown('SIGTERM');
  await starting;
  assert.deepEqual(h.exits, [0]);
  assert.equal(h.server.listening, false);
  assert.equal(closed, 1);
});

test('shutdown drains an in-flight request, refuses new connections, then closes resources once', async () => {
  let release;
  const inFlight = new Promise((resolve) => { release = resolve; });
  let closedAt;
  let responseAt;
  let closes = 0;
  const h = harness({
    close: async () => { closes++; closedAt = performance.now(); },
    handler: (req, res) => inFlight.then(() => { responseAt = performance.now(); res.end('done'); }),
  });
  await h.lifecycle.start(0);
  await once(h.server, 'listening');
  const { port } = h.server.address();
  const pending = fetch(`http://127.0.0.1:${port}/`);
  await delay(50);
  const first = h.lifecycle.shutdown('SIGTERM');
  const second = h.lifecycle.shutdown('SIGINT');
  assert.equal(first, second);
  assert.equal(h.app.locals.draining, true);
  assert.equal(await refused(port), true);
  release();
  const response = await pending;
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('connection'), 'close');
  assert.equal(await response.text(), 'done');
  await first;
  assert.deepEqual(h.exits, [0]);
  assert.equal(closes, 1);
  assert.ok(closedAt >= responseAt);
  assert.ok(h.records.some((r) => r.event === 'shutdown_complete'));
});

test('idle keep-alive connections do not hold shutdown open', async () => {
  const h = harness();
  await h.lifecycle.start(0);
  await once(h.server, 'listening');
  const agent = new http.Agent({ keepAlive: true });
  await new Promise((resolve) => http.get({ port: h.server.address().port, host: '127.0.0.1', agent }, (res) => { res.resume(); res.on('end', resolve); }));
  const started = performance.now();
  await h.lifecycle.shutdown('SIGTERM');
  assert.ok(performance.now() - started < 500);
  assert.deepEqual(h.exits, [0]);
  agent.destroy();
});

test('shutdown is forced with exit 1 when draining exceeds the budget', async () => {
  const h = harness({ handler: () => {}, budget: { ...budgets, shutdown: 300 } });
  await h.lifecycle.start(0);
  await once(h.server, 'listening');
  const socket = net.connect(h.server.address().port, '127.0.0.1');
  socket.on('error', () => {});
  socket.write('GET / HTTP/1.1\r\nHost: x\r\n\r\n');
  await delay(50);
  const started = performance.now();
  h.lifecycle.shutdown('SIGTERM');
  assert.equal(await h.exited, 1);
  const elapsed = performance.now() - started;
  assert.ok(elapsed >= 280 && elapsed < 600, `elapsed ${elapsed}`);
  assert.ok(h.records.some((r) => r.event === 'shutdown_forced'));
  socket.destroy();
  h.server.closeAllConnections();
});
