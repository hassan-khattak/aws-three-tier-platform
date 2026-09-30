'use strict';

const { loadConfig } = require('./lib/config');
const { createUpstream } = require('./lib/upstream');
const { createApp } = require('./lib/application');

const config = loadConfig();
const upstream = createUpstream({ statusUrl: config.statusUrl });
const app = createApp({ upstream });
app.locals.config = config;

module.exports = app;
