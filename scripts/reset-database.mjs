#!/usr/bin/env node
/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   reset-database.mjs                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

/**
 * reset-database.mjs
 *
 * Wipes all user data (public schema + GoTrue auth tables) and re-seeds the
 * database from scratch.  Useful for a clean development restart.
 *
 * Usage:
 *   node apps/baas/scripts/reset-database.mjs
 *   npm run db:reset               (from opposite-osiris/)
 *   npm run reset:database          (from opposite-osiris/)
 *
 * The script runs against the running `postgres` Docker Compose service.
 * Make sure `docker compose up -d postgres` is running before calling this.
 */

import { spawnSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '../../..');
const dockerEnv = { ...process.env, PGOPTIONS: process.env.PGOPTIONS || '-c search_path=public' };

// ─── helpers ─────────────────────────────────────────────────────────────────

const RESET = '\x1b[0m';
const BOLD = '\x1b[1m';
const RED = '\x1b[31m';
const YELLOW = '\x1b[33m';
const GREEN = '\x1b[32m';
const CYAN = '\x1b[36m';
const DIM = '\x1b[2m';

const log = {
  info: (msg) => console.log(`${CYAN}ℹ${RESET}  ${msg}`),
  ok: (msg) => console.log(`${GREEN}✔${RESET}  ${msg}`),
  warn: (msg) => console.log(`${YELLOW}⚠${RESET}  ${msg}`),
  error: (msg) => console.error(`${RED}✖${RESET}  ${msg}`),
  step: (msg) => console.log(`\n${BOLD}${CYAN}▸${RESET} ${BOLD}${msg}${RESET}`),
  dim: (msg) => console.log(`${DIM}  ${msg}${RESET}`),
};

function psql(sql, opts = {}) {
  const { silent = false } = opts;
  const result = spawnSync(
    'docker',
    [
      'compose',
      '--project-directory', repoRoot,
      'exec', '-T', 'postgres',
      'psql',
      '-U', 'postgres',
      '-d', 'postgres',
      '-v', 'ON_ERROR_STOP=1',
      '-c', sql,
    ],
    { cwd: repoRoot, encoding: 'utf8', env: dockerEnv },
  );

  if (result.status !== 0) {
    if (!silent) {
      log.error('psql error:');
      console.error(result.stderr);
    }
    throw new Error(`psql exited with ${result.status}: ${result.stderr?.trim()}`);
  }

  return result.stdout?.trim();
}

function psqlFile(filePath, opts = {}) {
  const { silent = false } = opts;
  const result = spawnSync(
    'docker',
    [
      'compose',
      '--project-directory', repoRoot,
      'exec', '-T', 'postgres',
      'psql',
      '-U', 'postgres',
      '-d', 'postgres',
      '-v', 'ON_ERROR_STOP=1',
      '-f', filePath,
    ],
    { cwd: repoRoot, encoding: 'utf8', env: dockerEnv },
  );

  if (result.status !== 0) {
    if (!silent) {
      log.error('psql error:');
      console.error(result.stderr);
    }
    throw new Error(`psql exited with ${result.status}: ${result.stderr?.trim()}`);
  }

  return result.stdout?.trim();
}

function isPostgresRunning() {
  const result = spawnSync(
    'docker',
    [
      'compose',
      '--project-directory', repoRoot,
      'ps', '--status', 'running', '--quiet', 'postgres',
    ],
    { cwd: repoRoot, encoding: 'utf8', env: dockerEnv },
  );
  return result.status === 0 && result.stdout.trim().length > 0;
}

async function confirm(question) {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((res) => {
    rl.question(question, (answer) => {
      rl.close();
      res(answer.trim().toLowerCase());
    });
  });
}

// ─── main ─────────────────────────────────────────────────────────────────────

console.log(`\n${BOLD}${RED}╔══════════════════════════════════════════════╗${RESET}`);
console.log(`${BOLD}${RED}║        DATABASE RESET — DESTRUCTIVE          ║${RESET}`);
console.log(`${BOLD}${RED}╚══════════════════════════════════════════════╝${RESET}\n`);
console.log(`This will ${RED}${BOLD}permanently delete${RESET} all users, sessions, tokens,`);
console.log(`activities and GoTrue auth accounts, then re-seed with demo data.\n`);

// ─── guard: non-interactive / --yes flag ─────────────────────────────────────
const forceYes = process.argv.includes('--yes') || process.argv.includes('-y');

if (forceYes) {
  log.warn('--yes flag detected, skipping confirmation prompt.');
} else {
  const answer = await confirm(`${YELLOW}Type "yes" to continue, anything else to abort: ${RESET}`);
  if (answer !== 'yes') {
    log.warn('Aborted — nothing was changed.');
    process.exit(0);
  }
}

// ─── guard: postgres must be up ──────────────────────────────────────────────
log.step('Checking Postgres container health…');

if (!isPostgresRunning()) {
  log.error('The `postgres` container is not running.');
  log.info(`Start the stack first:  ${DIM}docker compose up -d${RESET}`);
  process.exit(1);
}

log.ok('Postgres is running.');

// ─── 1. wipe GoTrue auth tables ──────────────────────────────────────────────
log.step('Wiping GoTrue auth tables (auth schema)…');

const authTruncate = `
  SET search_path = auth, public;
  TRUNCATE auth.refresh_tokens  CASCADE;
  TRUNCATE auth.one_time_tokens CASCADE;
  TRUNCATE auth.mfa_factors     CASCADE;
  TRUNCATE auth.sessions        CASCADE;
  TRUNCATE auth.identities      CASCADE;
  TRUNCATE auth.audit_log_entries;
  DELETE FROM auth.users;
`;

psql(authTruncate);
log.ok('auth.users and related auth tables cleared.');

// ─── 2. wipe public app tables ───────────────────────────────────────────────
log.step('Wiping public app tables…');

const publicTruncate = `
  SET search_path = public;
  TRUNCATE user_activities CASCADE;
  TRUNCATE user_tokens     CASCADE;
  TRUNCATE sessions        CASCADE;
  TRUNCATE users           RESTART IDENTITY CASCADE;
`;

psql(publicTruncate);
log.ok('public.users, sessions, user_tokens, user_activities cleared.');

// ─── 3. remove migration markers so seeds get re-applied ─────────────────────
log.step('Removing seed migration markers…');

psql(`
  DELETE FROM track_binocle_runtime_migrations
  WHERE marker LIKE '%_seeds';
`);
log.ok('Seed markers removed.');

// ─── 4. re-apply seeds ───────────────────────────────────────────────────────
log.step('Re-seeding with demo data…');

// The seeds file is mounted inside the postgres container as /project-init/04-seeds.sql
// via docker-compose.  We re-run it directly on the container FS.
// Check if the file is available in the container.
const checkResult = spawnSync(
  'docker',
  [
    'compose',
    '--project-directory', repoRoot,
    'exec', '-T', 'postgres',
    'test', '-f', '/project-init/04-seeds.sql',
  ],
  { cwd: repoRoot, encoding: 'utf8' },
);

if (checkResult.status === 0) {
  // File is already mounted — run directly.
  psqlFile('/project-init/04-seeds.sql');
  log.ok('Seeds applied from mounted /project-init/04-seeds.sql.');
} else {
  // Container doesn't have the file mounted (e.g. only postgres service running
  // without the db-init service).  Copy & exec the SQL inline via stdin.
  log.info('Seeds file not mounted in postgres container — piping it via docker exec…');

  const { readFileSync } = await import('node:fs');
  const seedsPath = resolve(repoRoot, 'models/seeds.sql');
  const seedsSql = `SET search_path = public;\n${readFileSync(seedsPath, 'utf8')}`;

  const result = spawnSync(
    'docker',
    [
      'compose',
      '--project-directory', repoRoot,
      'exec', '-T', 'postgres',
      'psql',
      '-U', 'postgres',
      '-d', 'postgres',
      '-v', 'ON_ERROR_STOP=1',
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      env: dockerEnv,
      input: seedsSql,
    },
  );

  if (result.status !== 0) {
    log.error('Failed to apply seeds:');
    console.error(result.stderr);
    process.exit(1);
  }

  log.ok('Seeds applied via stdin.');
}

// ─── 5. record seeds marker ──────────────────────────────────────────────────
psql(`
  INSERT INTO track_binocle_runtime_migrations (marker)
  VALUES ('track_binocle_20260504_seeds')
  ON CONFLICT DO NOTHING;
`);

// ─── done ─────────────────────────────────────────────────────────────────────
console.log(`\n${GREEN}${BOLD}✔ Database reset complete!${RESET}`);
console.log(`  ${DIM}10 demo users re-seeded (john.doe@example.com … hannah@example.com)${RESET}`);
console.log(`  ${DIM}Demo password hash: Str0ngP@ss (bcrypt $2b$12 from seeds.sql)${RESET}\n`);
