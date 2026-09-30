'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { EventEmitter } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');
const { createDatabase } = require('../lib/database');

const budgets = { request: 150, acquire: 50, query: 50 };
function client(query = async () => ({ rows: [{ time: new Date('2026-09-30T12:00:00Z') }] })) {
  const value = new EventEmitter();
  value.query = query;
  value.releases = [];
  value.release = (destroy) => value.releases.push(destroy);
  return value;
}
function pool(connect) {
  const value = new EventEmitter();
  value.connect = connect;
  value.end = async () => {};
  return value;
}
function adapter(connect, extra = {}) {
  return createDatabase({}, { pool: pool(connect), logger: () => {}, budgets, ...extra });
}

test('successful reads reuse the process pool and release each checkout once', async () => {
  const c = client();
  let queries = 0;
  c.query = async (query) => {
    assert.equal(query.text, 'SELECT now() AS time');
    queries++;
    return { rows: [{ time: new Date('2026-09-30T12:00:00Z') }] };
  };
  const db = adapter(async () => c);
  assert.equal(await db.readTime(), '2026-09-30T12:00:00.000Z');
  await db.readTime();
  assert.equal(queries, 2);
  assert.deepEqual(c.releases, [false, false]);
  await db.close();
});

test('one transient read failure retries once and discards the broken client', async () => {
  const bad = client(async () => { throw Object.assign(new Error('private DB address'), { code: 'ECONNRESET' }); });
  const good = client();
  let attempts = 0;
  const db = adapter(async () => ++attempts === 1 ? bad : good);
  assert.equal(await db.readTime(), '2026-09-30T12:00:00.000Z');
  assert.equal(attempts, 2);
  assert.deepEqual(bad.releases, [true]);
  assert.deepEqual(good.releases, [false]);
});

test('repeated connection failure is bounded to two attempts', async () => {
  let attempts = 0;
  const db = adapter(async () => { attempts++; throw Object.assign(new Error('private'), { code: 'ECONNREFUSED' }); });
  await assert.rejects(db.readTime(), { reason: 'CONNECTION_ERROR' });
  assert.equal(attempts, 2);
});

test('authentication, certificate and SQL failures never retry', async () => {
  for (const [code, reason] of [['28P01', 'AUTH_ERROR'], ['ERR_TLS_CERT_ALTNAME_INVALID', 'TLS_ERROR'], ['SELF_SIGNED_CERT_IN_CHAIN', 'TLS_ERROR'], ['42601', 'QUERY_ERROR']]) {
    let attempts = 0;
    const c = client(async () => { throw Object.assign(new Error('password=do-not-log'), { code }); });
    const db = adapter(async () => { attempts++; return c; });
    await assert.rejects(db.readTime(), (error) => {
      assert.equal(error.reason, reason);
      assert.equal(error.message, 'Database unavailable');
      return true;
    });
    assert.equal(attempts, 1);
    assert.deepEqual(c.releases, [true]);
  }
});

test('an acquisition that resolves after its deadline is destroyed without querying', async () => {
  let resolve;
  let queried = false;
  const c = client(async () => { queried = true; });
  const db = adapter(() => new Promise((done) => { resolve = done; }));
  await assert.rejects(db.readTime(), { reason: 'ACQUIRE_TIMEOUT' });
  resolve(c);
  await delay(0);
  assert.deepEqual(c.releases, [true]);
  assert.equal(queried, false);
});

test('a stuck query destroys its connection and does not retry', async () => {
  const c = client(() => new Promise(() => {}));
  let attempts = 0;
  const db = adapter(async () => { attempts++; return c; });
  await assert.rejects(db.readTime(), { reason: 'QUERY_TIMEOUT' });
  assert.deepEqual(c.releases, [true]);
  assert.equal(attempts, 1);
});

test('client disconnect discards an active query client', async () => {
  const controller = new AbortController();
  let started;
  const querying = new Promise((resolve) => { started = resolve; });
  const c = client(() => { started(); return new Promise(() => {}); });
  const db = adapter(async () => c);
  const pending = db.readTime({ signal: controller.signal });
  await querying;
  controller.abort();
  await assert.rejects(pending, { reason: 'CLIENT_ABORTED' });
  assert.deepEqual(c.releases, [true]);
});

test('idle pool errors are handled without logging the raw error', () => {
  const records = [];
  const p = pool(async () => client());
  createDatabase({}, { pool: p, logger: (record) => records.push(record), budgets });
  p.emit('error', Object.assign(new Error('private-password@private-host'), { code: 'ECONNRESET' }));
  assert.equal(records[0].event, 'db_idle_error');
  assert.equal(records[0].reason, 'CONNECTION_ERROR');
  assert.ok(!JSON.stringify(records).includes('private-password'));
});

test('invalid result data is not fabricated into a successful timestamp', async () => {
  const c = client(async () => ({ rows: [] }));
  const db = adapter(async () => c);
  await assert.rejects(db.readTime(), { reason: 'INVALID_RESULT' });
  assert.deepEqual(c.releases, [true]);
});
