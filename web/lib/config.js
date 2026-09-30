'use strict';

class ConfigurationError extends Error {
  constructor(field) {
    super(`Invalid or missing configuration: ${field}`);
    this.name = 'ConfigurationError';
    this.field = field;
  }
}

function loadConfig(env = process.env) {
  const portValue = env.PORT ?? '3000';
  if (!/^\d+$/.test(portValue) || Number(portValue) > 65535) throw new ConfigurationError('PORT');

  const raw = env.API_HOST;
  if (typeof raw !== 'string' || !raw.length || /[\s\0]/.test(raw)) throw new ConfigurationError('API_HOST');
  let base;
  try {
    base = new URL(raw);
  } catch {
    throw new ConfigurationError('API_HOST');
  }
  // A base URL only: the route appends /api/status itself, so a configured
  // /api path, credentials, query or fragment would produce a wrong target.
  const pathname = base.pathname.replace(/\/+$/, '');
  if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password
    || base.search || base.hash || /(^|\/)api$/.test(pathname)) {
    throw new ConfigurationError('API_HOST');
  }
  return {
    port: Number(portValue),
    statusUrl: new URL(`${pathname}/api/status`, base.origin).href,
  };
}

module.exports = { loadConfig, ConfigurationError };
