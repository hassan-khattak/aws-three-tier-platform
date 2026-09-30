'use strict';

const http = require('node:http');

async function listen(t, server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });
  return `http://127.0.0.1:${server.address().port}`;
}

// A controllable stand-in for the API. `handler` receives each request.
async function fakeApi(t, handler) {
  const requests = [];
  const url = await listen(t, http.createServer((request, response) => {
    requests.push({ url: request.url, headers: request.headers, request, response });
    handler(request, response);
  }));
  return { url, requests };
}

function json(response, status, body, headers = {}) {
  response.writeHead(status, { 'Content-Type': 'application/json', ...headers });
  response.end(typeof body === 'string' ? body : JSON.stringify(body));
}

const VALID = { time: '2026-09-30T12:00:00.000Z', request_uuid: 'ae245ca8-dd88-4796-af92-0b71c7a88be3' };

module.exports = { listen, fakeApi, json, VALID };
