'use strict';

const { spawn } = require('node:child_process');
const { once } = require('node:events');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');

// Spawns a service launcher and exposes its JSON log records so tests can
// wait on lifecycle events (startup_waiting, server_listening, shutdown_*).
function spawnService(service, environment = {}) {
  const child = spawn(process.execPath, ['bin/www'], {
    cwd: path.join(root, service),
    env: { PATH: process.env.PATH, NODE_ENV: 'production', PORT: '0', DEBUG: 'ldv:server', DEBUG_COLORS: '0', ...environment },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const records = [];
  const waiters = new Set();
  let port;
  let buffer = '';
  let output = '';
  const notify = () => { for (const waiter of waiters) waiter(); };
  const onData = (chunk) => {
    const text = chunk.toString();
    output = (output + text).slice(-16384);
    const match = output.match(/Listening on port (\d+)/);
    if (match) port = Number(match[1]);
    buffer += text;
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      try { records.push(JSON.parse(line)); } catch { /* debug output */ }
    }
    notify();
  };
  child.stdout.on('data', onData);
  child.stderr.on('data', onData);
  const exited = once(child, 'exit').then(([code, signal]) => { notify(); return { code, signal }; });

  function waitFor(predicate, milliseconds, description = 'condition') {
    return new Promise((resolve, reject) => {
      const check = () => {
        const value = predicate();
        if (value) { cleanup(); resolve(value); }
      };
      const timer = setTimeout(() => { cleanup(); reject(new Error(`Timed out waiting for ${description}: ${output}`)); }, milliseconds);
      const cleanup = () => { clearTimeout(timer); waiters.delete(check); };
      waiters.add(check);
      check();
    });
  }

  return {
    child,
    records,
    exited,
    output: () => output,
    url: () => `http://127.0.0.1:${port}`,
    waitFor,
    event: (name, milliseconds) => waitFor(() => records.find((record) => record.event === name), milliseconds, name),
    // Always leave no process behind, whatever the test outcome.
    async stop() {
      if (child.exitCode !== null || child.signalCode !== null) return exited;
      const force = setTimeout(() => child.kill('SIGKILL'), 25000);
      child.kill('SIGTERM');
      try { return await exited; } finally { clearTimeout(force); }
    },
  };
}

module.exports = { spawnService };
