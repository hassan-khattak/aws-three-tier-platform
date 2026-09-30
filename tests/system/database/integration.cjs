'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFile } = require('node:child_process');
const net = require('node:net');
const { promisify } = require('node:util');
const { performance } = require('node:perf_hooks');
const { setTimeout: delay } = require('node:timers/promises');
const { Pool, Client } = require('../../../api/node_modules/pg');
const { loadConfig } = require('../../../api/lib/config');
const { createDatabase } = require('../../../api/lib/database');
const { createApp } = require('../../../api/lib/application');
const { createTlsFixture } = require('../../helpers/tls-fixture.cjs');
const { spawnService } = require('../../helpers/service-process.cjs');
const { loadConfig: loadWebConfig } = require('../../../web/lib/config');
const { createUpstream } = require('../../../web/lib/upstream');
const { createApp: createWebApp } = require('../../../web/lib/application');

const root = path.resolve(__dirname, '../../..');
assert.equal(process.versions.node, fs.readFileSync(path.join(root, '.nvmrc'), 'utf8').trim());
const run = promisify(execFile);
const project = `assessment-db-${process.pid}-${Date.now()}`;
const certificates = createTlsFixture();
// Placeholder port keeps compose interpolation valid for cleanup if setup fails early.
let environment = { ...process.env, TEST_TLS_DIR: certificates.directory, TEST_DB_PORT: '0' };
const composeArguments = ['compose', '--project-name', project, '-f', path.join(root, 'compose.test.yaml')];
const resources = [];
const records = [];
let interrupted = false;
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { interrupted = true; });
const report = (check, details = {}) => console.log(JSON.stringify({ check, ...details }));
async function compose(args) {
  // After SIGINT/SIGTERM, only the cleanup command may still run.
  if (interrupted && args[0] !== 'down') throw new Error('Interrupted');
  const result = await run('docker', [...composeArguments, ...args], { cwd: root, env: environment, timeout: 180000, maxBuffer: 1024 * 1024 });
  return result.stdout.trim();
}
async function boundedCleanup(action) {
  let timer;
  try {
    await Promise.race([action(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Cleanup timed out')), 5000); })]);
  } finally { clearTimeout(timer); }
}
function trackDatabase(db) { resources.push(() => db.close()); return db; }
function trackPool(pool) {
  pool.on('error', () => {});
  resources.push(() => pool.end());
  return pool;
}
function freePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer().once('error', reject);
    probe.listen(0, '127.0.0.1', () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}
async function main() {
  environment = { ...process.env, TEST_TLS_DIR: certificates.directory, TEST_DB_PORT: String(await freePort()) };
  await compose(['config', '--quiet']);
  await compose(['up', '-d', '--wait', '--wait-timeout', '60']);
  const port = (await compose(['port', 'postgres', '5432'])).split(':').pop();
  const settings = {
    NODE_ENV: 'production', DB: 'assessment', DBUSER: 'assessment_app', DBPASS: 'local-test-only',
    DBHOST: 'localhost', DBPORT: port, DB_SSL: 'true', DB_CA_FILE: certificates.caFile,
  };
  const config = loadConfig(settings);
  const database = trackDatabase(createDatabase(config.database, { logger: (record) => records.push(record) }));
  const admin = trackPool(new Pool({ ...config.database, user: 'postgres', password: 'local-admin-only', max: 2, connectionTimeoutMillis: 1000 }));
  const version = (await admin.query('SHOW server_version')).rows[0].server_version;
  assert.match(version, /^16\.15\b/);
  assert.equal((await admin.query('SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()')).rows[0].ssl, true);
  report('fixture_ready', { project, version, tls: true });

  const app = createApp({ database, logger: (record) => records.push(record) });
  const server = await new Promise((resolve, reject) => {
    const value = app.listen(0, '127.0.0.1', () => resolve(value));
    value.once('error', reject);
  });
  resources.push(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });
  const apiPort = server.address().port;
  const endpoint = `http://127.0.0.1:${apiPort}/api/status`;
  async function request() {
    if (interrupted) throw new Error('Interrupted');
    const started = performance.now();
    const response = await fetch(endpoint, { signal: AbortSignal.timeout(4000) });
    return { status: response.status, body: await response.json(), duration: performance.now() - started };
  }
  // Freshness is judged against the database clock, not the host's: the
  // Docker VM clock can drift from the host between resyncs.
  const dbNow = async () => Date.parse((await admin.query('SELECT now() AS t')).rows[0].t);
  let reference = await dbNow();
  report('clock', { host_minus_db_ms: Date.now() - reference });
  function fresh(time) {
    return Math.abs(Date.parse(time) - reference) < 10000;
  }
  function success(result) {
    assert.equal(result.status, 200);
    assert.equal(result.body.length, 1);
    assert.match(result.body[0].request_uuid, /^[0-9a-f-]{36}$/);
    assert.ok(fresh(result.body[0].time));
    assert.ok(result.duration < 3500);
  }
  const webRecords = [];
  const webApp = createWebApp({ upstream: createUpstream(loadWebConfig({ API_HOST: `http://127.0.0.1:${apiPort}` })), logger: (record) => webRecords.push(record) });
  const webServer = await new Promise((resolve, reject) => {
    const value = webApp.listen(0, '127.0.0.1', () => resolve(value));
    value.once('error', reject);
  });
  resources.push(async () => {
    webServer.closeAllConnections();
    await new Promise((resolve) => webServer.close(resolve));
  });
  const webUrl = `http://127.0.0.1:${webServer.address().port}/`;
  async function page() {
    const started = performance.now();
    const response = await fetch(webUrl, { signal: AbortSignal.timeout(6000) });
    return { status: response.status, html: await response.text(), duration: performance.now() - started };
  }

  const responses = await Promise.all(Array.from({ length: 20 }, request));
  responses.forEach(success);
  assert.equal(new Set(responses.map((r) => r.body[0].request_uuid)).size, 20);
  assert.ok(database.stats().total <= 5);
  assert.equal(database.stats().idle, database.stats().total);
  assert.equal(database.stats().waiting, 0);
  // The UUID shown in the page must be the one the API logged for a real DB read.
  const rendered = await page();
  assert.equal(rendered.status, 200);
  const shown = rendered.html.match(/Welcome, it's ([^<]+)<\/p>[\s\S]*<pre>([0-9a-f-]{36})<\/pre>/);
  assert.ok(shown, 'page shows time and UUID');
  assert.ok(fresh(shown[1]));
  assert.ok(records.some((record) => record.request_id === shown[2] && record.route === '/api/status' && record.status === 200));
  report('web_end_to_end', { status: rendered.status, ms: Math.round(rendered.duration), time_from_db: true, uuid_from_api: true });
  report('concurrent_http', { count: responses.length, max_ms: Math.round(Math.max(...responses.map((r) => r.duration))), pool: database.stats() });

  for (const [name, changes, reason] of [
    ['untrusted_ca', { DB_CA_FILE: certificates.untrustedCaFile }, 'TLS_ERROR'],
    ['hostname_mismatch', { DBHOST: '127.0.0.1' }, 'TLS_ERROR'],
    ['invalid_password', { DBPASS: 'wrong-test-password' }, 'AUTH_ERROR'],
  ]) {
    const db = createDatabase(loadConfig({ ...settings, ...changes }).database, { logger: () => {} });
    try {
      await assert.rejects(db.readTime(), { reason });
      report(name, { rejected: true });
    } finally { await db.close(); }
  }

  // Operator initialization script: creates the role, then is rerun safely.
  const initEnv = {
    PATH: process.env.PATH, DBHOST: 'localhost', DBPORT: port, DB: 'assessment', DB_CA_FILE: certificates.caFile,
    ADMIN_USER: 'postgres', ADMIN_PASS: 'local-admin-only', APP_USER: 'init_probe_role', APP_PASS: 'init-probe-only-password',
  };
  const initRuns = [];
  for (let i = 0; i < 2; i++) {
    const result = await run(process.execPath, ['scripts/init-database.js'], { cwd: path.join(root, 'api'), env: initEnv, timeout: 60000 }).catch((error) => error);
    const lines = String(result.stdout || '').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
    assert.equal(result.code ?? 0, 0, String(result.stdout) + String(result.stderr));
    assert.ok(!String(result.stdout).includes('init-probe-only-password') && !String(result.stdout).includes('local-admin-only'));
    initRuns.push(lines);
  }
  assert.equal(initRuns[0].find((r) => r.event === 'db_init_role').role_created, true);
  assert.equal(initRuns[1].find((r) => r.event === 'db_init_role').role_created, false);
  const initChecks = initRuns[1].filter((r) => r.event === 'db_init_check');
  assert.deepEqual(initChecks.map((r) => r.check), ['app_select_now', 'app_create_table', 'app_write_in_writable_transaction', 'untrusted_ca_rejected']);
  assert.ok(initChecks.slice(1).every((r) => r.refused));
  const badInit = await run(process.execPath, ['scripts/init-database.js'], { cwd: path.join(root, 'api'), env: { ...initEnv, ADMIN_PASS: 'wrong-admin-password' }, timeout: 60000 }).catch((error) => error);
  assert.equal(badInit.code, 1);
  assert.ok(!String(badInit.stdout).includes('wrong-admin-password'));
  report('operator_init', { first_run_created_role: true, rerun_created_role: false, checks: initChecks.map((r) => r.check), bad_admin_password_exit: badInit.code });

  const readerPool = trackPool(new Pool({ ...config.database, connectionTimeoutMillis: 1000 }));
  await assert.rejects(readerPool.query('CREATE TABLE forbidden_write (id integer)'), (error) => ['25006', '42501'].includes(error.code));
  report('readonly_role', { write_rejected: true });

  const heldPool = new Pool({ ...config.database, max: 5, connectionTimeoutMillis: 1000 });
  const exhausted = trackDatabase(createDatabase(config.database, { pool: heldPool, logger: () => {} }));
  const held = await Promise.all(Array.from({ length: 5 }, () => heldPool.connect()));
  const started = performance.now();
  let exhaustedMs;
  try {
    await assert.rejects(exhausted.readTime(), { reason: 'ACQUIRE_TIMEOUT' });
    exhaustedMs = performance.now() - started;
    assert.ok(exhaustedMs < 1500);
    assert.equal(exhausted.stats().waiting, 0);
  } finally { held.forEach((client) => client.release()); }
  assert.ok(await exhausted.readTime());
  report('pool_exhaustion', { bounded: true, wait_ms: Math.round(exhaustedMs), recovered: true, pool: exhausted.stats() });

  let slow = true;
  class SlowClient extends Client {
    query(query, ...args) {
      if (slow && query?.text === 'SELECT now() AS time') query = { ...query, text: 'SELECT now() AS time FROM pg_sleep(3) /* assessment_slow_query */' };
      return super.query(query, ...args);
    }
  }
  const slowPool = new Pool({ ...config.database, Client: SlowClient, max: 5, connectionTimeoutMillis: 1000, statement_timeout: 1000, application_name: 'assessment-slow-test' });
  const slowDb = trackDatabase(createDatabase(config.database, { pool: slowPool, logger: () => {} }));
  const slowStarted = performance.now();
  await assert.rejects(slowDb.readTime(), { reason: 'QUERY_TIMEOUT' });
  const slowMs = performance.now() - slowStarted;
  assert.ok(slowMs < 1500);
  await delay(100);
  const active = await admin.query("SELECT count(*)::int AS n FROM pg_stat_activity WHERE application_name = 'assessment-slow-test' AND state = 'active'");
  assert.equal(active.rows[0].n, 0);
  slow = false;
  assert.ok(await slowDb.readTime());
  report('slow_query', { bounded: true, timeout_ms: Math.round(slowMs), active_backends_after_timeout: active.rows[0].n, recovered: true });

  // Real launchers: API admitted by the database, web admitted by that API.
  const processes = [];
  const launch = (service, env) => {
    const value = spawnService(service, env);
    processes.push(value);
    resources.push(() => value.stop());
    return value;
  };
  const status = async (url) => (await fetch(url, { signal: AbortSignal.timeout(7000) })).status;
  const apiProcess = launch('api', settings);
  await apiProcess.event('server_listening', 15000);
  const webProcess = launch('web', { API_HOST: apiProcess.url() });
  await webProcess.event('server_listening', 15000);
  for (const target of [apiProcess, webProcess]) {
    assert.equal(await status(`${target.url()}/health/live`), 200);
    assert.equal(await status(`${target.url()}/health/ready`), 200);
  }
  report('launcher_admission', { api: 'listening after DB check', web: 'listening after API check' });

  await compose(['stop', '-t', '1', 'postgres']);
  for (const target of [apiProcess, webProcess]) {
    assert.equal(await status(`${target.url()}/health/ready`), 503);
    assert.equal(await status(`${target.url()}/health/live`), 200);
  }
  const lateApi = launch('api', settings);
  await lateApi.event('startup_waiting', 10000);
  await delay(1500);
  assert.ok(!lateApi.records.some((record) => record.event === 'server_listening'));
  report('health_during_outage', { ready: 503, live: 200, new_api_admitted: false });
  const failures = await Promise.all(Array.from({ length: 3 }, request));
  for (const failure of failures) {
    assert.equal(failure.status, 503);
    assert.deepEqual(failure.body.error, { code: 'DATABASE_UNAVAILABLE' });
    assert.ok(failure.duration < 3500);
  }
  const outagePage = await page();
  assert.equal(outagePage.status, 503);
  assert.ok(outagePage.duration < 5500);
  assert.ok(!outagePage.html.includes(String(apiPort)));
  report('web_during_outage', { status: outagePage.status, ms: Math.round(outagePage.duration) });
  await compose(['start', 'postgres']);
  assert.equal((await compose(['port', 'postgres', '5432'])).split(':').pop(), port);
  const recoveryStarted = performance.now();
  let recovered;
  do {
    recovered = await request();
    if (recovered.status === 200) break;
    await delay(100);
  } while (performance.now() - recoveryStarted < 30000);
  reference = await dbNow();
  success(recovered);
  assert.equal(server.address().port, apiPort);
  reference = await dbNow();
  const afterRecovery = await Promise.all(Array.from({ length: 20 }, request));
  afterRecovery.forEach(success);
  assert.equal(database.stats().waiting, 0);
  assert.ok(database.stats().total <= 5);
  assert.equal(database.stats().idle, database.stats().total);
  assert.equal((await page()).status, 200);
  const readyAgain = async (target) => {
    const until = performance.now() + 30000;
    while (performance.now() < until) {
      if (await status(`${target.url()}/health/ready`) === 200) return true;
      await delay(200);
    }
    return false;
  };
  assert.ok(await readyAgain(apiProcess));
  assert.ok(await readyAgain(webProcess));
  await lateApi.event('server_listening', 60000);
  assert.equal(await status(`${lateApi.url()}/health/ready`), 200);
  for (const target of processes) assert.equal(target.child.exitCode, null);
  report('health_after_restart', { ready: 200, restarted: false, waiting_api_admitted: true });
  for (const target of processes) {
    const started = performance.now();
    target.child.kill('SIGTERM');
    const { code } = await target.exited;
    const ms = Math.round(performance.now() - started);
    assert.equal(code, 0);
    assert.ok(ms < 20000);
    assert.ok(target.records.some((record) => record.event === 'shutdown_complete'));
    for (const forbidden of ['local-test-only', certificates.directory]) assert.ok(!target.output().includes(forbidden));
    report('launcher_sigterm', { service: target.records[0]?.service, exit: code, ms });
  }
  report('database_restart', { api_restarted: false, outage_503_count: failures.length, outage_max_ms: Math.round(Math.max(...failures.map((f) => f.duration))), recovery_ms: Math.round(performance.now() - recoveryStarted), requests_after_recovery: 20, pool: database.stats() });

  const logs = JSON.stringify([...records, ...webRecords]);
  for (const forbidden of ['local-test-only', 'local-admin-only', 'wrong-test-password', certificates.directory]) assert.ok(!logs.includes(forbidden));
  assert.ok(records.some((record) => record.event === 'db_idle_error'));
  assert.ok(records.some((record) => record.status === 503));
  if (interrupted) throw new Error('Interrupted');
  report('sanitized_logs', { checked: true });
}

(async () => {
  let failed = false;
  try { await main(); }
  catch (error) { failed = true; console.error(error); }
  finally {
    for (const close of resources.reverse()) {
      try { await boundedCleanup(close); }
      catch (error) { failed = true; console.error('Resource cleanup failed:', error.message); }
    }
    try {
      await compose(['down', '--volumes', '--remove-orphans']);
      report('fixture_cleanup', { project, removed: true });
    } catch (error) { failed = true; console.error('Docker cleanup failed for', project, error.message); }
    certificates.cleanup();
    process.exitCode = failed ? 1 : 0;
  }
})();
