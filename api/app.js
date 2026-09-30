'use strict';

const { loadConfig } = require('./lib/config');
const { createDatabase } = require('./lib/database');
const { createApp } = require('./lib/application');

const config = loadConfig();
const database = createDatabase(config.database);
const app = createApp({ database });
app.locals.config = config;

module.exports = app;
