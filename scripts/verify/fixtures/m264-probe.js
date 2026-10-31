// m264-probe.js — runs inside one pg-clients container as `docker exec -i <c> node - <mode> [arg]`
// (scripts/lib/lib-m264-pg-clients-live.sh, ADR 0032 W1/W3/NP7/NP12). It loads the image's own
// compiled OutboxService / AuditService and node_modules, so the pool under test is the one the
// service builds from its rendered env. Prints one JSON line last; never prints a DSN.
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const SUFFIX = '?sslmode=verify-full&sslrootcert=/etc/engine-pg-ca/ca.pem';
const [mode, arg] = process.argv.slice(2);
const dist = path.join('/app/dist/apps', process.env.APP_NAME || '');
const SSL_ROW = 'select ssl, version from pg_stat_ssl where pid = pg_backend_pid()';
const hold = () => new Promise((resolve) => setTimeout(resolve, 1500));
const config = { get: (key, fallback) => process.env[key] ?? fallback };

function envFacts() {
  return {
    pgsslmode: 'PGSSLMODE' in process.env,
    pgsslrootcert: 'PGSSLROOTCERT' in process.env,
    extraCa: 'NODE_EXTRA_CA_CERTS' in process.env,
    audit: 'AUDIT_DATABASE_URL' in process.env,
    suffixed: (process.env.DATABASE_URL || '').endsWith(SUFFIX),
  };
}

// The pool's own TLS row, read while the service still holds the connection.
async function sslOf(pool) {
  const { rows } = await pool.query(SSL_ROW);
  await hold();
  return rows[0];
}

async function emit() {
  const file = path.join(dist, 'apps/query-router/src/query/outbox.service.js');
  const svc = new (require(file).OutboxService)(config);
  const input = {
    engine: 'postgresql',
    resource: 'm264_probe',
    op: 'insert',
    data: { id: arg },
    result: { rows: [{ id: arg }], rowCount: 1 },
  };
  try {
    await svc.emitForQuery(input);
    return { emitted: true, ssl: await sslOf(svc.pool) };
  } catch (err) {
    return { emitted: false, error: err.message };
  } finally {
    await svc.onModuleDestroy();
  }
}

async function audit() {
  const file = path.join(dist, 'libs/common/src/audit/audit.service.js');
  const svc = new (require(file).AuditService)();
  svc.onModuleInit();
  await svc.record({ requestId: arg, action: 'm264.probe', resource: arg });
  let ssl = null;
  try {
    ssl = await sslOf(svc.pool);
  } catch (err) {
    ssl = { error: err.message };
  }
  await svc.onModuleDestroy();
  return { audited: true, ssl };
}

async function plain() {
  const { Client } = require('pg');
  const client = new Client({ connectionString: arg });
  await client.connect();
  try {
    return { plain: (await client.query(SSL_ROW)).rows[0] };
  } finally {
    await client.end();
  }
}

// NP12: the versions the image ships, and what they make of the suffixed DSN.
function parse() {
  const version = (pkg) =>
    JSON.parse(fs.readFileSync(`/app/node_modules/${pkg}/package.json`, 'utf8')).version;
  const { parse: parseDsn } = require('pg-connection-string');
  const cfg = parseDsn(process.env.DATABASE_URL || '');
  const corrupted = parseDsn(`postgres://u@postgres/db?a=1${SUFFIX}`);
  return {
    pg: version('pg'),
    pcs: version('pg-connection-string'),
    verified: typeof cfg.ssl === 'object' && cfg.ssl.rejectUnauthorized !== false,
    hasCa: typeof cfg.ssl === 'object' && String(cfg.ssl.ca || '').includes('BEGIN CERTIFICATE'),
    corruptedParam: corrupted.a,
  };
}

const modes = { env: async () => envFacts(), emit, audit, plain, parse: async () => parse() };

(modes[mode] || (async () => ({ error: `unknown mode ${mode}` })))()
  .then((out) => process.stdout.write(`M264 ${JSON.stringify({ env: envFacts(), ...out })}\n`))
  .catch((err) => {
    process.stdout.write(`M264 ${JSON.stringify({ error: err.message })}\n`);
    process.exitCode = 1;
  });
