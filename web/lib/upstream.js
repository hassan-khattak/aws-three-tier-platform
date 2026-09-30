'use strict';

const BUDGETS = Object.freeze({ request: 5000, maxBodyBytes: 64 * 1024 });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

class UpstreamError extends Error {
  // status 503: API unreachable, timed out or reporting itself unavailable.
  // status 502: API answered with something that breaks the response contract.
  constructor(status, reason) {
    super(status === 503 ? 'Service Unavailable' : 'Bad Gateway');
    this.name = 'UpstreamError';
    this.status = status;
    this.reason = reason;
  }
}

async function readBody(response, limit) {
  const declared = Number(response.headers.get('content-length'));
  if (declared > limit) {
    await response.body?.cancel().catch(() => {});
    throw new UpstreamError(502, 'BODY_TOO_LARGE');
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body ?? []) {
    size += chunk.byteLength;
    if (size > limit) throw new UpstreamError(502, 'BODY_TOO_LARGE');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

function parseStatus(text) {
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    throw new UpstreamError(502, 'INVALID_JSON');
  }
  const first = Array.isArray(body) ? body[0] : undefined;
  if (!first || typeof first !== 'object') throw new UpstreamError(502, 'INVALID_SCHEMA');
  const { time, request_uuid: requestUuid } = first;
  if (typeof time !== 'string' || !Number.isFinite(Date.parse(time))) throw new UpstreamError(502, 'INVALID_TIME');
  if (typeof requestUuid !== 'string' || !UUID.test(requestUuid)) throw new UpstreamError(502, 'INVALID_UUID');
  return { time, requestUuid };
}

function createUpstream({ statusUrl, budgets = BUDGETS, fetchImpl = fetch }) {
  async function readStatus({ signal } = {}) {
    if (signal?.aborted) throw new UpstreamError(503, 'CLIENT_ABORTED');
    // One deadline covers connect, headers and body, and cancels the socket.
    const deadline = AbortSignal.timeout(budgets.request);
    const combined = signal ? AbortSignal.any([deadline, signal]) : deadline;
    try {
      const response = await fetchImpl(statusUrl, {
        method: 'GET',
        redirect: 'manual',
        headers: { accept: 'application/json' },
        signal: combined,
      });
      if (response.status !== 200) {
        await response.body?.cancel().catch(() => {});
        if ([502, 503, 504].includes(response.status)) throw new UpstreamError(503, 'UPSTREAM_UNAVAILABLE');
        throw new UpstreamError(502, 'UNEXPECTED_STATUS');
      }
      if (!/^application\/json\b/i.test(response.headers.get('content-type') || '')) {
        await response.body?.cancel().catch(() => {});
        throw new UpstreamError(502, 'INVALID_CONTENT_TYPE');
      }
      return parseStatus(await readBody(response, budgets.maxBodyBytes));
    } catch (error) {
      if (error instanceof UpstreamError) throw error;
      if (signal?.aborted) throw new UpstreamError(503, 'CLIENT_ABORTED');
      if (deadline.aborted) throw new UpstreamError(503, 'UPSTREAM_TIMEOUT');
      throw new UpstreamError(503, 'UPSTREAM_UNREACHABLE');
    }
  }
  return { readStatus };
}

module.exports = { createUpstream, UpstreamError, BUDGETS };
