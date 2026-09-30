'use strict';

const fs = require('node:fs');
const { X509Certificate } = require('node:crypto');
const tls = require('node:tls');

class ConfigurationError extends Error {
  constructor(field) {
    super(`Invalid or missing configuration: ${field}`);
    this.name = 'ConfigurationError';
    this.field = field;
  }
}

function loadConfig(env = process.env) {
  function required(name) {
    const value = env[name];
    if (typeof value !== 'string' || !value.length || /[\r\n\0]/.test(value)) throw new ConfigurationError(name);
    return value;
  }
  function port(name, fallback, minimum) {
    const value = env[name] ?? fallback;
    if (!/^\d+$/.test(value) || Number(value) < minimum || Number(value) > 65535) throw new ConfigurationError(name);
    return Number(value);
  }
  const database = required('DB');
  const user = required('DBUSER');
  const password = required('DBPASS');
  const host = required('DBHOST');
  if (/[\s/\\]/.test(host)) throw new ConfigurationError('DBHOST');
  const dbPort = port('DBPORT', '5432', 1);
  const listenPort = port('PORT', '3000', 0);
  const sslEnabled = env.DB_SSL ?? 'true';
  if (!['true', 'false'].includes(sslEnabled)) throw new ConfigurationError('DB_SSL');
  if (env.NODE_ENV === 'production' && sslEnabled !== 'true') throw new ConfigurationError('DB_SSL');
  if (env.NODE_TLS_REJECT_UNAUTHORIZED === '0') throw new ConfigurationError('NODE_TLS_REJECT_UNAUTHORIZED');

  let ssl = false;
  if (sslEnabled === 'true') {
    const file = required('DB_CA_FILE');
    let ca;
    try {
      ca = fs.readFileSync(file, 'utf8');
      const certificates = ca.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g);
      if (!certificates?.length) throw new Error('No certificates');
      for (const certificate of certificates) new X509Certificate(certificate);
    } catch {
      throw new ConfigurationError('DB_CA_FILE');
    }
    ssl = {
      ca,
      rejectUnauthorized: true,
      minVersion: 'TLSv1.2',
      // Check the configured endpoint, including IP addresses, not an override.
      checkServerIdentity: (_servername, certificate) => tls.checkServerIdentity(host, certificate),
    };
  }
  return {
    port: listenPort,
    database: { database, user, password, host, port: dbPort, ssl },
  };
}

module.exports = { loadConfig, ConfigurationError };
