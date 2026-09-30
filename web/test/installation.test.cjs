'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const path = require('node:path');
const test = require('node:test');
const startService = require('../../tests/helpers/start-service.cjs');
const { fakeApi, json, VALID } = require('../../tests/helpers/fake-api.cjs');

test('the production web launcher imports its dependencies and serves the existing stylesheet', { timeout: 10000 }, async (t) => {
  const api = await fakeApi(t, (req, res) => json(res, 200, [VALID]));
  const url = await startService(t, 'web', { API_HOST: api.url });
  const response = await fetch(`${url}/stylesheets/style.css`, { signal: AbortSignal.timeout(2000) });
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /text\/css/);
  assert.ok((await response.text()).length > 0);
});

test('the existing Jade view renders with the pinned toolchain and escapes display values', () => {
  const jade = require('jade');
  const html = jade.renderFile(path.join(__dirname, '../views/index.jade'), {
    title: '3tier App',
    time: '2026-09-30T12:00:00.000Z',
    request_uuid: '<script>unexpected()</script>',
  });
  assert.match(html, /2026-09-30T12:00:00\.000Z/);
  assert.match(html, /\/images\/nyan\.gif/);
  assert.ok(!html.includes('<script>unexpected()</script>'));
  assert.match(html, /&lt;script&gt;/);
});

test('the production web launcher renders a controlled API response', { timeout: 10000 }, async (t) => {
  const requests = [];
  const fixture = { time: '2026-09-30T12:00:00.000Z', request_uuid: 'ae245ca8-dd88-4796-af92-0b71c7a88be3' };
  const upstream = http.createServer((request, response) => {
    requests.push(request.url);
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify([fixture]));
  });
  await new Promise((resolve, reject) => {
    upstream.once('error', reject);
    upstream.listen(0, '127.0.0.1', resolve);
  });
  t.after(async () => {
    upstream.closeAllConnections();
    await new Promise((resolve) => upstream.close(resolve));
  });
  const url = await startService(t, 'web', { API_HOST: `http://127.0.0.1:${upstream.address().port}` });
  const response = await fetch(url, { signal: AbortSignal.timeout(2000) });
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.ok(html.includes(fixture.time));
  assert.ok(html.includes(fixture.request_uuid));
  // One admission check at startup, then one call for the page.
  assert.deepEqual(requests, ['/api/status', '/api/status']);
});

// Jade's patched constant evaluator and minifier must retain their existing API.
test('Jade remains compatible with its scoped dependency overrides', () => {
  const jade = require('jade');
  assert.equal(jade.render('p= 1 + 2'), '<p>3</p>');
  const html = jade.render('script\n  :uglify-js\n    var answer = 1 + 2;');
  assert.match(html, /<script>/);
  assert.match(html, /answer/);
  assert.match(html, /3/);
});
