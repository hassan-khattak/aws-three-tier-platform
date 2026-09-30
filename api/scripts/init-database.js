'use strict';

// One-off database initialization, run as a short-lived operator task (never
// an HTTP route). Creates or updates the least-privilege application role so
// it matches the application secret, then proves what that role can and
// cannot do. Safe to rerun: an existing role keeps the password stored in the
// secret. Credentials arrive as environment variables injected by ECS from
// Secrets Manager; none are logged.
//
// Environment: DBHOST, DBPORT, DB, DB_CA_FILE (TLS is always verified),
// ADMIN_USER, ADMIN_PASS, APP_USER, APP_PASS.

const fs = require('node:fs');
const tls = require('node:tls');
const { Client } = require('pg');
const { log } = require('../lib/logger');

const ROLE_NAME = /^[a-z_][a-z0-9_]{0,62}$/;

function required(name) {
  const value = process.env[name];
  if (!value) throw Object.assign(new Error(`missing ${name}`), { code: 'CONFIGURATION_ERROR', field: name });
  return value;
}

function connection(user, password, ca) {
  const host = required('DBHOST');
  return {
    host,
    port: Number(process.env.DBPORT || 5432),
    database: required('DB'),
    user,
    password,
    connectionTimeoutMillis: 10000,
    query_timeout: 10000,
    application_name: 'assessment-db-init',
    ssl: { ca, rejectUnauthorized: true, minVersion: 'TLSv1.2', checkServerIdentity: (_name, cert) => tls.checkServerIdentity(host, cert) },
  };
}

async function withClient(settings, action) {
  const client = new Client(settings);
  client.on('error', () => {});
  await client.connect();
  try {
    return await action(client);
  } finally {
    await client.end().catch(() => {});
  }
}

async function expectFailure(label, action) {
  try {
    await action();
  } catch (error) {
    return { check: label, refused: true, code: error.code || 'ERROR' };
  }
  throw Object.assign(new Error(`${label} unexpectedly succeeded`), { code: 'CHECK_FAILED' });
}

async function main() {
  const ca = fs.readFileSync(required('DB_CA_FILE'), 'utf8');
  const database = required('DB');
  const appUser = required('APP_USER');
  const appPass = required('APP_PASS');
  if (!ROLE_NAME.test(appUser)) throw Object.assign(new Error('invalid APP_USER'), { code: 'CONFIGURATION_ERROR', field: 'APP_USER' });
  const admin = connection(required('ADMIN_USER'), required('ADMIN_PASS'), ca);

  const created = await withClient(admin, async (client) => {
    const exists = (await client.query('SELECT 1 FROM pg_roles WHERE rolname = $1', [appUser])).rowCount === 1;
    const role = client.escapeIdentifier(appUser);
    const db = client.escapeIdentifier(database);
    // Utility statements cannot take bind parameters; the literal is escaped
    // by the driver and never logged.
    const password = client.escapeLiteral(appPass);
    await client.query('BEGIN');
    await client.query(exists
      ? `ALTER ROLE ${role} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION PASSWORD ${password}`
      : `CREATE ROLE ${role} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION PASSWORD ${password}`);
    await client.query(`REVOKE ALL ON DATABASE ${db} FROM PUBLIC`);
    await client.query(`GRANT CONNECT ON DATABASE ${db} TO ${role}`);
    await client.query('REVOKE CREATE ON SCHEMA public FROM PUBLIC');
    await client.query(`GRANT USAGE ON SCHEMA public TO ${role}`);
    await client.query(`ALTER ROLE ${role} SET default_transaction_read_only = on`);
    await client.query('COMMIT');
    return !exists;
  });
  log({ level: 'info', event: 'db_init_role', role_created: created });

  const app = connection(appUser, appPass, ca);
  const checks = await withClient(app, async (client) => {
    const row = (await client.query('SELECT now() AS time, current_user AS who, (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()) AS ssl')).rows[0];
    if (row.who !== appUser || row.ssl !== true) throw Object.assign(new Error('unexpected session'), { code: 'CHECK_FAILED' });
    const results = [{ check: 'app_select_now', ok: true, tls: row.ssl }];
    results.push(await expectFailure('app_create_table', () => client.query('CREATE TABLE init_probe (id integer)')));
    results.push(await expectFailure('app_write_in_writable_transaction', async () => {
      await client.query('BEGIN READ WRITE');
      try { await client.query('CREATE TEMP TABLE init_probe (id integer)'); await client.query('INSERT INTO init_probe VALUES (1)'); }
      finally { await client.query('ROLLBACK'); }
    }));
    return results;
  });
  // A CA the server certificate does not chain to must be rejected.
  checks.push(await expectFailure('untrusted_ca_rejected', () => withClient(connection(appUser, appPass, tls.rootCertificates.join('\n')), (c) => c.query('SELECT 1'))));
  for (const result of checks) log({ level: 'info', event: 'db_init_check', ...result });
  log({ level: 'info', event: 'db_init_complete' });
}

main().catch((error) => {
  // Fixed fields only: never the raw message, which could contain endpoints.
  log({ level: 'error', event: 'db_init_failed', code: error.code || 'ERROR', ...(error.field ? { field: error.field } : {}) });
  process.exitCode = 1;
});
