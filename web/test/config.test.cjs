'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { loadConfig, ConfigurationError } = require('../lib/config');

test('API_HOST is a base URL; the status path is appended exactly once', () => {
  for (const [value, expected] of [
    ['http://internal-alb.example', 'http://internal-alb.example/api/status'],
    ['http://internal-alb.example/', 'http://internal-alb.example/api/status'],
    ['https://10.0.1.5:8080/prefix/', 'https://10.0.1.5:8080/prefix/api/status'],
  ]) {
    assert.equal(loadConfig({ API_HOST: value }).statusUrl, expected);
  }
  assert.equal(loadConfig({ API_HOST: 'http://a.example' }).port, 3000);
  assert.equal(loadConfig({ API_HOST: 'http://a.example', PORT: '0' }).port, 0);
});

test('invalid configuration fails without reflecting the value', () => {
  for (const change of [
    {}, { API_HOST: '' }, { API_HOST: 'not a url' }, { API_HOST: 'ftp://private-host.example' },
    { API_HOST: 'http://user:private-password@private-host.example' },
    { API_HOST: 'http://private-host.example/api' }, { API_HOST: 'http://private-host.example/api/' },
    { API_HOST: 'http://private-host.example?x=1' }, { API_HOST: 'http://private-host.example#x' },
    { API_HOST: 'http://a.example', PORT: '65536' }, { API_HOST: 'http://a.example', PORT: '80x' },
  ]) {
    assert.throws(() => loadConfig(change), (error) => {
      assert.ok(error instanceof ConfigurationError);
      assert.ok(!error.message.includes('private'));
      return true;
    });
  }
});

test('the launcher exits nonzero with sanitized configuration diagnostics', () => {
  const child = spawnSync(process.execPath, ['bin/www'], {
    cwd: path.resolve(__dirname, '..'),
    env: { PATH: process.env.PATH, NODE_ENV: 'production', API_HOST: 'http://user:private-password@host.example' },
    encoding: 'utf8', timeout: 5000,
  });
  assert.equal(child.status, 1);
  const output = child.stdout + child.stderr;
  assert.ok(!output.includes('private-password'));
  assert.ok(!output.includes('Error:'));
  const record = JSON.parse(child.stdout.trim());
  assert.equal(record.event, 'startup_failed');
  assert.equal(record.field, 'API_HOST');
});
