'use strict';

const { setTimeout: sleep } = require('node:timers/promises');

const BUDGETS = Object.freeze({ admission: 60000, retry: 1000, shutdown: 20000 });

// Admission: listen only after one successful dependency check within the
// admission budget. Shutdown: refuse new connections, mark readiness down,
// drain in-flight requests, release resources once, and exit within budget.
function createLifecycle({ app, server, check, close = async () => {}, logger, budgets = BUDGETS, exit = (code) => process.exit(code) }) {
  const stopping = new AbortController();
  const active = new Set();
  let state = 'starting';
  let shutdownPromise;
  server.on('request', (req, res) => {
    active.add(res);
    res.once('close', () => active.delete(res));
  });

  async function admit() {
    const deadline = Date.now() + budgets.admission;
    for (let attempt = 1; ; attempt++) {
      const remaining = deadline - Date.now();
      if (remaining <= 0 || stopping.signal.aborted) return false;
      const signal = AbortSignal.any([AbortSignal.timeout(remaining), stopping.signal]);
      try {
        await check({ signal });
        return !stopping.signal.aborted;
      } catch (error) {
        if (stopping.signal.aborted) return false;
        logger({ level: 'warn', event: 'startup_waiting', attempt, reason: error?.reason || 'DEPENDENCY_ERROR' });
      }
      const wait = Math.min(budgets.retry, deadline - Date.now());
      if (wait > 0) await sleep(wait, undefined, { signal: stopping.signal }).catch(() => {});
    }
  }

  async function release() {
    try {
      await close();
    } catch {
      logger({ level: 'error', event: 'resource_close_failed' });
    }
  }

  async function start(port) {
    const admitted = await admit();
    if (state === 'draining') return;
    if (!admitted) {
      state = 'failed';
      logger({ level: 'error', event: 'startup_failed', code: 'DEPENDENCY_UNAVAILABLE' });
      await release();
      exit(1);
      return;
    }
    state = 'serving';
    server.listen(port);
  }

  function shutdown(signal) {
    if (shutdownPromise) return shutdownPromise;
    const wasServing = state === 'serving';
    state = 'draining';
    app.locals.draining = true;
    stopping.abort();
    logger({ level: 'info', event: 'shutdown_started', signal });
    const force = setTimeout(() => {
      logger({ level: 'error', event: 'shutdown_forced' });
      exit(1);
    }, budgets.shutdown);
    shutdownPromise = (async () => {
      if (wasServing) {
        // close() stops accepting and waits for open connections to end.
        // Idle keep-alive sockets close now; a busy one closes right after its
        // response instead of lingering for the keep-alive timeout.
        const closed = new Promise((resolve) => server.close(resolve));
        for (const res of active) {
          if (!res.headersSent) res.setHeader('Connection', 'close');
          res.once('finish', () => setImmediate(() => server.closeIdleConnections()));
        }
        server.closeIdleConnections();
        await closed;
      }
      await release();
      clearTimeout(force);
      logger({ level: 'info', event: 'shutdown_complete' });
      exit(0);
    })();
    return shutdownPromise;
  }

  return { start, shutdown, state: () => state };
}

module.exports = { createLifecycle, BUDGETS };
