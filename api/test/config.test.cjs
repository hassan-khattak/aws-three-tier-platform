'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const { loadConfig, ConfigurationError } = require('../lib/config');
const { createTlsFixture } = require('../../tests/helpers/tls-fixture.cjs');

let certificates;
test.before(() => { certificates = createTlsFixture(); });
test.after(() => certificates.cleanup());
const environment = () => ({ NODE_ENV: 'production', DB: 'assessment', DBUSER: 'reader', DBPASS: 'private-password', DBHOST: 'localhost', DBPORT: '5432', DB_SSL: 'true', DB_CA_FILE: certificates.caFile });

test('production config enforces trusted TLS and endpoint verification', () => {
  const config = loadConfig(environment());
  assert.equal(config.port, 3000);
  assert.equal(config.database.port, 5432);
  assert.equal(config.database.ssl.rejectUnauthorized, true);
  assert.equal(config.database.ssl.minVersion, 'TLSv1.2');
  assert.equal(typeof config.database.ssl.checkServerIdentity, 'function');
});

test('invalid configuration fails without reflecting secrets or paths', () => {
  for (const change of [
    { DB: '' }, { DBUSER: '' }, { DBPASS: '' }, { DBHOST: 'https://private-db.example' },
    { DBPORT: '5432oops' }, { DBPORT: '0' }, { PORT: '-1' }, { PORT: '65536' },
    { DB_SSL: 'false' }, { DB_SSL: 'yes' }, { DB_CA_FILE: '/private/nonexistent-ca' },
    { NODE_TLS_REJECT_UNAUTHORIZED: '0' },
  ]) {
    assert.throws(() => loadConfig({ ...environment(), ...change }), (error) => {
      assert.ok(error instanceof ConfigurationError);
      assert.ok(!error.message.includes('private-password'));
      assert.ok(!error.message.includes('/private/nonexistent-ca'));
      assert.ok(!error.message.includes('private-db.example'));
      return true;
    });
  }
});

test('only an explicit nonproduction setting permits a plaintext local fixture', () => {
  const config = loadConfig({ ...environment(), NODE_ENV: 'test', DB_SSL: 'false', PORT: '0' });
  assert.equal(config.database.ssl, false);
  assert.equal(config.port, 0);
});

test('the launcher exits nonzero with sanitized configuration diagnostics', () => {
  const child = spawnSync(process.execPath, ['bin/www'], {
    cwd: path.resolve(__dirname, '..'),
    env: { ...environment(), DBPORT: 'secret-invalid-value' },
    encoding: 'utf8', timeout: 5000,
  });
  assert.equal(child.status, 1);
  const output = child.stdout + child.stderr;
  assert.ok(!output.includes('private-password'));
  assert.ok(!output.includes('secret-invalid-value'));
  assert.ok(!output.includes('Error:'));
  const record = JSON.parse(child.stdout.trim());
  assert.equal(record.event, 'startup_failed');
  assert.equal(record.field, 'DBPORT');
});
