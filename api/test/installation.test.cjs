'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { spawnService } = require('../../tests/helpers/service-process.cjs');
const { createTlsFixture } = require('../../tests/helpers/tls-fixture.cjs');

test('the production API launcher imports its dependencies and holds admission until the database answers', { timeout: 15000 }, async (t) => {
  const certificates = createTlsFixture();
  t.after(() => certificates.cleanup());
  const api = spawnService('api', { DB: 'assessment', DBUSER: 'reader', DBPASS: 'test-only', DBHOST: 'localhost', DBPORT: '9', DB_SSL: 'true', DB_CA_FILE: certificates.caFile });
  t.after(() => api.stop());
  const waiting = await api.event('startup_waiting', 8000);
  assert.equal(waiting.service, 'api');
  assert.ok(!api.records.some((r) => r.event === 'server_listening'));
  assert.ok(!api.output().includes('test-only'));
  const started = Date.now();
  const { code } = await api.stop();
  assert.equal(code, 0);
  assert.ok(Date.now() - started < 5000);
});
