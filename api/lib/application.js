'use strict';

const express = require('express');
const { randomUUID } = require('node:crypto');
const { performance } = require('node:perf_hooks');
const { log } = require('./logger');

function createApp({ database, logger = log }) {
  const app = express();
  app.disable('x-powered-by');
  app.locals.database = database;

  app.use((req, res, next) => {
    const started = performance.now();
    const controller = new AbortController();
    req.requestId = randomUUID();
    req.databaseSignal = controller.signal;
    res.setHeader('X-Request-ID', req.requestId);
    res.setHeader('Cache-Control', 'no-store');
    if (app.locals.draining) res.setHeader('Connection', 'close');
    const record = (event) => logger({
      level: res.statusCode >= 500 ? 'error' : 'info',
      event,
      request_id: req.requestId,
      route: req.route?.path || 'unmatched',
      status: res.statusCode,
      duration_ms: Math.round(performance.now() - started),
      ...(req.failureReason ? { reason: req.failureReason } : {}),
    });
    res.once('finish', () => record('request_finished'));
    res.once('close', () => {
      if (!res.writableFinished) {
        controller.abort();
        record('request_aborted');
      }
    });
    next();
  });

  // Liveness reports only that the process serves HTTP; it never touches the
  // database, so a shared outage does not make every task restart.
  app.get('/health/live', (req, res) => res.status(200).json({ status: 'ok' }));
  app.get('/health/ready', async (req, res) => {
    if (app.locals.draining) return res.status(503).json({ status: 'draining' });
    try {
      await database.readTime({ signal: req.databaseSignal });
      if (!res.destroyed) res.status(200).json({ status: 'ready' });
    } catch (error) {
      req.failureReason = error.code === 'DATABASE_UNAVAILABLE' ? error.reason : 'INTERNAL_ERROR';
      if (!res.destroyed) res.status(503).json({ status: 'unavailable' });
    }
  });

  app.get('/api/status', async (req, res) => {
    try {
      const time = await database.readTime({ signal: req.databaseSignal });
      if (!res.destroyed) res.status(200).json([{ time, request_uuid: req.requestId }]);
    } catch (error) {
      req.failureReason = error.code === 'DATABASE_UNAVAILABLE' ? error.reason : 'INTERNAL_ERROR';
      if (!res.destroyed) res.status(503).json({ error: { code: 'DATABASE_UNAVAILABLE' }, request_uuid: req.requestId });
    }
  });

  app.use((req, res) => res.status(404).json({ error: { code: 'NOT_FOUND' }, request_uuid: req.requestId }));
  app.use((error, req, res, next) => {
    if (res.headersSent) return next(error);
    req.failureReason = 'INTERNAL_ERROR';
    const status = error instanceof URIError ? 400 : 500;
    res.status(status).json({ error: { code: status === 400 ? 'BAD_REQUEST' : 'INTERNAL_ERROR' }, request_uuid: req.requestId });
  });
  return app;
}

module.exports = { createApp };
