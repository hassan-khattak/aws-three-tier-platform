'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');

module.exports = async function startService(t, service, environment = {}) {
  const pinnedVersion = fs.readFileSync(path.join(root, '.nvmrc'), 'utf8').trim();
  assert.equal(process.versions.node, pinnedVersion, 'Run tests with the Node version in .nvmrc');

  const child = spawn(process.execPath, ['bin/www'], {
    cwd: path.join(root, service),
    env: {
      PATH: process.env.PATH,
      NODE_ENV: 'production',
      PORT: '0',
      DEBUG: 'ldv:server',
      DEBUG_COLORS: '0',
      API_HOST: 'http://127.0.0.1:9',
      ...environment,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  t.after(async () => {
    if (!child.pid || child.exitCode !== null || child.signalCode !== null) return;
    const exited = once(child, 'exit');
    const force = setTimeout(() => child.kill('SIGKILL'), 2000);
    child.kill('SIGTERM');
    try {
      await exited;
    } finally {
      clearTimeout(force);
    }
  });

  return new Promise((resolve, reject) => {
    let output = '';
    const timeout = setTimeout(() => finish(new Error(`Service startup timed out: ${output}`)), 5000);
    const onData = (chunk) => {
      output = (output + chunk.toString()).slice(-8192);
      const match = output.match(/Listening on port (\d+)/);
      if (match) finish(null, `http://127.0.0.1:${match[1]}`);
    };
    const onExit = (code, signal) => finish(new Error(`Service exited (${code ?? signal}): ${output}`));
    const onError = (error) => finish(error);

    function finish(error, url) {
      clearTimeout(timeout);
      child.stdout.off('data', onData);
      child.stderr.off('data', onData);
      child.off('exit', onExit);
      child.off('error', onError);
      // Keep draining output so a child cannot block on a full pipe.
      child.stdout.resume();
      child.stderr.resume();
      if (error) reject(error);
      else resolve(url);
    }

    child.stdout.on('data', onData);
    child.stderr.on('data', onData);
    child.once('exit', onExit);
    child.once('error', onError);
  });
};
