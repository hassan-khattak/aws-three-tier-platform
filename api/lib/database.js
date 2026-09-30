'use strict';

const { Pool } = require('pg');
const { performance } = require('node:perf_hooks');
const { log } = require('./logger');

const BUDGETS = Object.freeze({ request: 3000, acquire: 1000, query: 1000 });
const TRANSIENT = new Set(['ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'ENOTFOUND', 'EAI_AGAIN', 'EHOSTUNREACH', 'ENETUNREACH', '57P01', '57P02', '57P03', '53300', '08000', '08001', '08003', '08004', '08006', '08007']);

class DatabaseUnavailableError extends Error {
  constructor(reason) {
    super('Database unavailable');
    this.name = 'DatabaseUnavailableError';
    this.code = 'DATABASE_UNAVAILABLE';
    this.reason = reason;
  }
}

function classify(error) {
  if (error instanceof DatabaseUnavailableError) return error.reason;
  const code = String(error?.code || '');
  if (/CERT|TLS|SSL|SELF_SIGNED|UNABLE_TO_VERIFY|UNABLE_TO_GET_ISSUER/.test(code)) return 'TLS_ERROR';
  if (code.startsWith('28')) return 'AUTH_ERROR';
  if (TRANSIENT.has(code) || ['Connection terminated unexpectedly', 'Connection terminated'].includes(error?.message)) return 'CONNECTION_ERROR';
  if (['timeout exceeded when trying to connect', 'Connection terminated due to connection timeout'].includes(error?.message)) return 'ACQUIRE_TIMEOUT';
  if (code === '57014' || error?.message === 'Query read timeout') return 'QUERY_TIMEOUT';
  return 'QUERY_ERROR';
}

// Observe the underlying operation even after timeout: no unhandled rejection,
// and any client acquired too late is destroyed without ever executing SQL.
function bounded(operation, milliseconds, reason, signal, onLateValue = () => {}) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const cleanup = () => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
    };
    const fail = (failure) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(failure);
    };
    const abort = () => fail(new DatabaseUnavailableError('CLIENT_ABORTED'));
    const timer = setTimeout(() => fail(new DatabaseUnavailableError(reason)), Math.max(0, milliseconds));
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) abort();
    Promise.resolve(operation).then((value) => {
      if (settled) {
        onLateValue(value);
        return;
      }
      settled = true;
      cleanup();
      resolve(value);
    }, fail);
  });
}

function createDatabase(config, { pool: injectedPool, logger = log, budgets = BUDGETS } = {}) {
  const pool = injectedPool || new Pool({
    ...config,
    max: 5,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: budgets.acquire,
    statement_timeout: budgets.query,
    query_timeout: budgets.query,
    application_name: 'assessment-api',
  });
  let closing;
  pool.on('error', (error) => logger({ level: 'error', event: 'db_idle_error', reason: classify(error) }));

  async function readTime({ signal } = {}) {
    const deadline = performance.now() + budgets.request;
    for (let attempt = 0; attempt < 2; attempt++) {
      if (closing) throw new DatabaseUnavailableError('POOL_CLOSED');
      if (signal?.aborted) throw new DatabaseUnavailableError('CLIENT_ABORTED');
      let client;
      let discard = false;
      const onClientError = () => { discard = true; };
      try {
        let remaining = deadline - performance.now();
        if (remaining <= 0) throw new DatabaseUnavailableError('REQUEST_TIMEOUT');
        client = await bounded(pool.connect(), Math.min(budgets.acquire, remaining), 'ACQUIRE_TIMEOUT', signal, (lateClient) => lateClient.release(true));
        client.on('error', onClientError);
        remaining = deadline - performance.now();
        if (remaining <= 0) throw new DatabaseUnavailableError('REQUEST_TIMEOUT');
        const queryBudget = Math.min(budgets.query, remaining);
        const result = await bounded(client.query({ text: 'SELECT now() AS time', query_timeout: queryBudget }), queryBudget, 'QUERY_TIMEOUT', signal);
        const time = result.rows?.[0]?.time;
        const date = time instanceof Date ? time : new Date(time);
        if (result.rows?.length !== 1 || time == null || !Number.isFinite(date.getTime())) throw new DatabaseUnavailableError('INVALID_RESULT');
        return date.toISOString();
      } catch (error) {
        discard = true;
        const reason = classify(error);
        // Only this fixed read may retry. Auth, TLS, query/queue timeout and
        // invalid configuration/results never amplify into another attempt.
        if (attempt === 0 && reason === 'CONNECTION_ERROR' && !signal?.aborted && performance.now() < deadline) continue;
        throw new DatabaseUnavailableError(reason);
      } finally {
        if (client) {
          client.removeListener('error', onClientError);
          // pg's public destroy-release path closes an active query's socket.
          client.release(discard);
        }
      }
    }
    throw new DatabaseUnavailableError('REQUEST_TIMEOUT');
  }

  return {
    readTime,
    close() {
      if (!closing) closing = pool.end();
      return closing;
    },
    stats() {
      return { total: pool.totalCount, idle: pool.idleCount, waiting: pool.waitingCount };
    },
  };
}

module.exports = { createDatabase, DatabaseUnavailableError, BUDGETS };
