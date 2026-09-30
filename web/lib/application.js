'use strict';

const express = require('express');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { performance } = require('node:perf_hooks');
const { log } = require('./logger');
const routes = require('../routes/index');

const MESSAGES = { 400: 'Bad Request', 404: 'Not Found', 500: 'Internal Server Error', 502: 'Bad Gateway', 503: 'Service Unavailable' };

function createApp({ upstream, logger = log }) {
  const app = express();
  app.disable('x-powered-by');
  app.set('views', path.join(__dirname, '../views'));
  app.set('view engine', 'jade');
  app.locals.upstream = upstream;

  // Static assets may be cached for 5 minutes (CloudFront caches them at the
  // edge); dynamic responses below are always no-store.
  app.use(express.static(path.join(__dirname, '../public'), { maxAge: '5m' }));

  app.use((req, res, next) => {
    const started = performance.now();
    const controller = new AbortController();
    req.requestId = randomUUID();
    req.upstreamSignal = controller.signal;
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

  // Liveness never calls the API. Readiness proves web -> API -> database via
  // /api/status: /health/ready on the shared load balancer would route back
  // to web itself.
  app.get('/health/live', (req, res) => res.status(200).json({ status: 'ok' }));
  app.get('/health/ready', async (req, res) => {
    if (app.locals.draining) return res.status(503).json({ status: 'draining' });
    try {
      await upstream.readStatus({ signal: req.upstreamSignal });
      if (!res.destroyed) res.status(200).json({ status: 'ready' });
    } catch (error) {
      req.failureReason = error.reason || 'INTERNAL_ERROR';
      if (!res.destroyed) res.status(503).json({ status: 'unavailable' });
    }
  });

  app.use('/', routes);

  app.use((req, res, next) => next(Object.assign(new Error('Not Found'), { status: 404 })));
  // Error pages carry only a fixed message and status: never the upstream
  // address, raw error text or a stack trace, in any environment.
  app.use((error, req, res, next) => {
    if (res.headersSent) return next(error);
    let status = Number.isInteger(error.status) && MESSAGES[error.status] ? error.status : 500;
    if (error instanceof URIError) status = 400;
    if (!req.failureReason && status >= 500) req.failureReason = error.reason || 'INTERNAL_ERROR';
    res.status(status).render('error', { title: MESSAGES[status], message: MESSAGES[status], error: { status } });
  });
  return app;
}

module.exports = { createApp };
