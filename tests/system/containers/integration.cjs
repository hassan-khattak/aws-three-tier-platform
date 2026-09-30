'use strict';

// Runs the production-shaped images (linux/amd64, read-only, 0.25 vCPU /
// 512 MiB) against the disposable PostgreSQL/TLS fixture and checks image
// shape, the browser path, outage/recovery, capacity and shutdown.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { performance } = require('node:perf_hooks');
const { setTimeout: delay } = require('node:timers/promises');
const { createTlsFixture } = require('../../helpers/tls-fixture.cjs');

const root = path.resolve(__dirname, '../../..');
assert.equal(process.versions.node, fs.readFileSync(path.join(root, '.nvmrc'), 'utf8').trim());
const run = promisify(execFile);
const project = `assessment-images-${process.pid}-${Date.now()}`;
const certificates = createTlsFixture();
const SECRETS = ['local-test-only', 'local-admin-only'];
let environment = { ...process.env, TEST_TLS_DIR: certificates.directory, TEST_DB_PORT: '0', TEST_API_PORT: '0', TEST_WEB_PORT: '0' };
const report = (check, details = {}) => console.log(JSON.stringify({ check, ...details }));
let interrupted = false;
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { interrupted = true; });

async function docker(args, timeout = 300000) {
  // After SIGINT/SIGTERM, only the cleanup command may still run.
  if (interrupted && args[args.indexOf('--profile') + 2] !== 'down') throw new Error('Interrupted');
  const result = await run('docker', args, { cwd: root, env: environment, timeout, maxBuffer: 16 * 1024 * 1024 });
  return result.stdout.trim();
}
const compose = (args, timeout) => docker(['compose', '--project-name', project, '-f', path.join(root, 'compose.test.yaml'), '--profile', 'images', ...args], timeout);
function freePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer().once('error', reject);
    probe.listen(0, '127.0.0.1', () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}
async function get(url, timeout = 8000) {
  const started = performance.now();
  const response = await fetch(url, { signal: AbortSignal.timeout(timeout) });
  return { status: response.status, headers: response.headers, text: await response.text(), ms: performance.now() - started };
}
async function until(description, predicate, milliseconds) {
  const deadline = performance.now() + milliseconds;
  while (performance.now() < deadline) {
    if (interrupted) throw new Error('Interrupted');
    try { if (await predicate()) return; } catch { /* retry */ }
    await delay(250);
  }
  throw new Error(`Timed out: ${description}`);
}
const percentile = (values, p) => values.slice().sort((a, b) => a - b)[Math.min(values.length - 1, Math.ceil((p / 100) * values.length) - 1)];

async function main() {
  environment = {
    ...environment,
    TEST_DB_PORT: String(await freePort()), TEST_API_PORT: String(await freePort()), TEST_WEB_PORT: String(await freePort()),
  };
  const api = `http://127.0.0.1:${environment.TEST_API_PORT}`;
  const web = `http://127.0.0.1:${environment.TEST_WEB_PORT}`;
  await compose(['config', '--quiet']);

  // Image shape.
  for (const service of ['api', 'web']) {
    const image = `assessment-${service}:local`;
    const config = JSON.parse(await docker(['image', 'inspect', image, '--format', '{{json .}}']));
    assert.equal(config.Architecture, 'amd64');
    assert.equal(config.Os, 'linux');
    assert.equal(config.Config.User, 'node');
    assert.deepEqual(config.Config.Entrypoint, ['node', 'bin/www']);
    assert.ok(!config.Config.Cmd?.length);
    assert.equal(config.Config.StopSignal, 'SIGTERM');
    const env = config.Config.Env.join('\n');
    for (const name of ['DBPASS', 'DBUSER', 'API_HOST']) assert.ok(!env.includes(`${name}=`), `${service} image env has ${name}`);
    const listing = await docker(['run', '--rm', '--platform', 'linux/amd64', '--entrypoint', 'sh', image, '-c',
      'node --version; npm --version; id -un; find /app -not -path "/app/node_modules/*" -type f | sort; '
      + 'grep -rIl -e local-test-only -e local-admin-only -e "BEGIN PRIVATE KEY" /app 2>/dev/null | head -5; true']);
    const [nodeVersion, npmVersion, user, ...files] = listing.split('\n');
    assert.equal(nodeVersion, 'v24.21.0');
    assert.equal(npmVersion, '11.19.0');
    assert.equal(user, 'node');
    for (const file of files) {
      assert.ok(!/\/(test|\.git|\.env|\.npmrc|Dockerfile|README)/.test(file) && !file.endsWith('.env'), `${service} image contains ${file}`);
      assert.ok(file.startsWith('/app/'), `${service} unexpected ${file}`);
    }
    const size = Number(await docker(['image', 'inspect', image, '--format', '{{.Size}}']));
    report('image_shape', { service, id: config.Id.slice(7, 19), arch: config.Architecture, user: config.Config.User, entrypoint: config.Config.Entrypoint, files: files.length, size_mb: Math.round(size / 1e6), secrets_found: 0 });
  }

  // Start the stack and wait for readiness-gated health checks.
  const upStarted = performance.now();
  await compose(['up', '-d', '--wait', '--wait-timeout', '120', 'postgres', 'api', 'web'], 180000);
  report('stack_ready', { ms: Math.round(performance.now() - upStarted) });

  for (const service of ['api', 'web']) {
    const id = await compose(['ps', '-q', service]);
    const state = JSON.parse(await docker(['inspect', id, '--format', '{{json .}}']));
    assert.equal(state.HostConfig.ReadonlyRootfs, true);
    assert.equal(state.HostConfig.NanoCpus, 250000000);
    assert.equal(state.HostConfig.Memory, 512 * 1024 * 1024);
    // `docker exec` is avoided: under amd64 emulation on arm64 it needs a
    // writable temp path that a read-only container does not have.
    // Ignore compose health-check probes; on arm64 hosts args include the
    // Rosetta wrapper, so match the node command itself.
    const processes = (await docker(['top', id, '-o', 'pid,args'])).split('\n').slice(1).filter((line) => !line.includes('/health/ready'));
    assert.equal(processes.length, 1, `${service} runs one process: ${processes}`);
    assert.match(processes[0], /\bnode (--no-opt -r \S+ )?bin\/www$/);
    assert.ok(!/\b(sh|bash|docker-entrypoint)\b/.test(processes[0]));
  }
  for (const service of ['api', 'web']) {
    // A fresh read-only container of the same image: the runtime user can
    // write nowhere, so no writable path is required at runtime.
    const probe = "const fs=require('fs');for(const d of ['/app','/tmp','/home/node']){try{fs.writeFileSync(d+'/probe','x');console.log('writable '+d)}catch(e){console.log(e.code+' '+d)}}";
    const output = await docker(['run', '--rm', '--platform', 'linux/amd64', '--read-only', '--entrypoint', 'node', `assessment-${service}:local`, '-e', probe]);
    assert.ok(!output.includes('writable'), output);
  }
  report('runtime_hardening', { read_only_rootfs: true, writable_paths: 0, pid1: 'node bin/www', cpus: 0.25, memory_mib: 512 });

  const page = await get(`${web}/`);
  assert.equal(page.status, 200);
  const shown = page.text.match(/Welcome, it's ([^<]+)<\/p>[\s\S]*<pre>([0-9a-f-]{36})<\/pre>/);
  assert.ok(shown);
  // Judge freshness against the database clock (the VM clock can drift).
  const dbNow = Date.parse(await compose(['exec', '-T', 'postgres', 'psql', '-U', 'postgres', '-d', 'assessment', '-tAc', "SELECT to_json(now())#>>'{}'"]));
  assert.ok(Math.abs(Date.parse(shown[1]) - dbNow) < 10000);
  const status = await get(`${api}/api/status`);
  assert.equal(status.status, 200);
  const [row] = JSON.parse(status.text);
  assert.match(row.request_uuid, /^[0-9a-f-]{36}$/);
  const css = await get(`${web}/stylesheets/style.css`);
  assert.equal(css.status, 200);
  for (const base of [api, web]) {
    assert.equal((await get(`${base}/health/live`)).status, 200);
    assert.equal((await get(`${base}/health/ready`)).status, 200);
  }
  report('browser_path', { web_status: page.status, web_ms: Math.round(page.ms), api_status: status.status, tls_to_db: true });

  // Capacity at the planned task size: sustained concurrent page views.
  const total = 200;
  const concurrency = 20;
  const latencies = [];
  const failures = [];
  let next = 0;
  const loadStarted = performance.now();
  await Promise.all(Array.from({ length: concurrency }, async () => {
    while (next < total) {
      next++;
      const result = await get(`${web}/`, 10000).catch((error) => ({ status: error.name, ms: 10000 }));
      latencies.push(result.ms);
      if (result.status !== 200) failures.push(result.status);
    }
  }));
  const loadSeconds = (performance.now() - loadStarted) / 1000;
  const stats = {};
  for (const service of ['api', 'web']) {
    const id = await compose(['ps', '-q', service]);
    stats[service] = await docker(['stats', '--no-stream', '--format', '{{.MemUsage}} cpu={{.CPUPerc}}', id]);
  }
  assert.equal(failures.length, 0, `failures: ${failures.slice(0, 5)}`);
  report('capacity', {
    requests: total, concurrency, failures: failures.length, rps: Math.round(total / loadSeconds),
    p50_ms: Math.round(percentile(latencies, 50)), p95_ms: Math.round(percentile(latencies, 95)), max_ms: Math.round(Math.max(...latencies)),
    memory_after: stats, emulated_amd64_on_arm64: process.arch === 'arm64',
  });

  // Database outage and recovery without restarting either container.
  const ids = { api: await compose(['ps', '-q', 'api']), web: await compose(['ps', '-q', 'web']) };
  const startedAt = {};
  for (const [service, id] of Object.entries(ids)) startedAt[service] = await docker(['inspect', id, '--format', '{{.State.StartedAt}}']);
  await compose(['stop', '-t', '1', 'postgres']);
  const outage = await get(`${web}/`);
  assert.equal(outage.status, 503);
  assert.ok(outage.ms < 5500);
  assert.equal((await get(`${api}/health/ready`)).status, 503);
  assert.equal((await get(`${api}/health/live`)).status, 200);
  assert.equal((await get(`${web}/health/live`)).status, 200);
  await compose(['start', 'postgres']);
  await until('web page after DB restart', async () => (await get(`${web}/`)).status === 200, 60000);
  for (const [service, id] of Object.entries(ids)) {
    assert.equal(await docker(['inspect', id, '--format', '{{.State.StartedAt}}']), startedAt[service], `${service} restarted`);
  }
  report('database_outage', { web_status: outage.status, web_ms: Math.round(outage.ms), api_ready: 503, live: 200, recovered: true, containers_restarted: false });

  // Logs are structured and sanitized.
  const logs = await compose(['logs', '--no-color', '--no-log-prefix', 'api', 'web']);
  const records = logs.split('\n').filter((line) => line.startsWith('{')).map((line) => JSON.parse(line));
  assert.ok(records.some((r) => r.service === 'api' && r.route === '/api/status' && r.request_id && Number.isInteger(r.duration_ms)));
  assert.ok(records.some((r) => r.service === 'web' && r.route === '/' && r.status === 503));
  for (const secret of SECRETS) assert.ok(!logs.includes(secret));
  assert.ok(!/\n\s+at /.test(logs));
  report('container_logs', { json_records: records.length, secrets_found: 0, stack_traces: 0 });

  // Graceful stop: web first (as a rolling update would drain it), then API.
  for (const service of ['web', 'api']) {
    const pending = service === 'web' ? get(`${web}/`, 10000).catch((error) => ({ status: error.name })) : null;
    const started = performance.now();
    await compose(['stop', '-t', '30', service], 60000);
    const ms = Math.round(performance.now() - started);
    const exitCode = Number(await docker(['inspect', ids[service], '--format', '{{.State.ExitCode}}']));
    assert.equal(exitCode, 0, `${service} exit code`);
    assert.ok(ms < 20000, `${service} stop took ${ms} ms`);
    const shutdown = await compose(['logs', '--no-color', '--no-log-prefix', service]);
    assert.ok(shutdown.includes('"event":"shutdown_complete"'));
    report('graceful_stop', { service, exit_code: exitCode, ms, in_flight_status: pending ? (await pending).status : undefined });
  }
}

(async () => {
  let failed = false;
  try { await main(); }
  catch (error) { failed = true; console.error(error); }
  finally {
    try {
      await compose(['down', '--volumes', '--remove-orphans', '--timeout', '5'], 120000);
      report('fixture_cleanup', { project, removed: true });
    } catch (error) { failed = true; console.error('Docker cleanup failed for', project, error.message); }
    certificates.cleanup();
    process.exitCode = failed ? 1 : 0;
  }
})();
