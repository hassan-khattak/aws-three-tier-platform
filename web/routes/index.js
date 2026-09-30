'use strict';

const express = require('express');

const router = express.Router();

/* GET home page. */
router.get('/', async (req, res, next) => {
  try {
    const { time, requestUuid } = await req.app.locals.upstream.readStatus({ signal: req.upstreamSignal });
    if (res.destroyed) return;
    res.render('index', {
      title: '3tier App',
      request_uuid: requestUuid,
      time,
    });
  } catch (error) {
    if (res.destroyed) return;
    req.failureReason = error.reason || 'INTERNAL_ERROR';
    next(error);
  }
});

module.exports = router;
