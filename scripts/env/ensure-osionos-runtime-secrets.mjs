/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ensure-osionos-runtime-secrets.mjs                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '../../..');
const rootEnvPath = resolve(repoRoot, '.env.local');
const osionosEnvPath = resolve(repoRoot, 'apps/osionos/app/.env');
const rotate = process.argv.includes('--rotate');

const generatedKeys = new Set([
  'OSIONOS_BRIDGE_SHARED_SECRET',
  'OSIONOS_APP_SESSION_SECRET',
  'OSIONOS_BRIDGE_EMAIL_HASH_SALT',
]);

const legacyUrlDefaults = new Map([
  ['OSIONOS_APP_URL', 'http://localhost:3001'],
  ['OSIONOS_ALLOWED_ORIGIN', 'http://localhost:3001'],
  ['PUBLIC_OSIONOS_APP_URL', 'http://localhost:3001'],
  ['VITE_API_URL', 'http://localhost:4000'],
  ['VITE_PRISMATICA_URL', 'http://localhost:4322'],
]);

function secret() {
  return randomBytes(48).toString('base64url');
}

function readEnv(path) {
  if (!existsSync(path)) return { lines: [], values: new Map() };
  const lines = readFileSync(path, 'utf8').split(/\r?\n/);
  const values = new Map();
  for (const line of lines) {
    const match = /^([A-Za-z_]\w*)=(.*)$/.exec(line);
    if (match) values.set(match[1], match[2]);
  }
  return { lines, values };
}

function upsertEnv(path, updates) {
  const { lines, values } = readEnv(path);
  const nextLines = [...lines];
  let changed = false;

  for (const [key, value] of Object.entries(updates)) {
    const existing = values.get(key);
    const shouldSet = rotate || existing === undefined || existing === '' || /^replace-with-/i.test(existing) || existing === legacyUrlDefaults.get(key);
    if (!shouldSet) continue;

    const nextLine = `${key}=${value}`;
    const index = nextLines.findIndex((line) => line.startsWith(`${key}=`));
    if (index >= 0) nextLines[index] = nextLine;
    else nextLines.push(nextLine);
    changed = true;
  }

  if (changed) {
    const output = nextLines.join('\n').replace(/\n*$/, '\n');
    writeFileSync(path, output, { mode: 0o600 });
  }

  return changed;
}

const updates = {
  OSIONOS_BRIDGE_SHARED_SECRET: secret(),
  OSIONOS_APP_SESSION_SECRET: secret(),
  OSIONOS_BRIDGE_EMAIL_HASH_SALT: secret(),
};

const osionosLocalUrl = process.env.OSIONOS_LOCAL_URL ?? 'https://localhost:3001';
const prismaticaLocalUrl = process.env.PRISMATICA_LOCAL_URL ?? process.env.PUBLIC_SITE_URL ?? 'https://localhost:4322';

const rootChanged = upsertEnv(rootEnvPath, {
  ...updates,
  OSIONOS_APP_URL: osionosLocalUrl,
  OSIONOS_ALLOWED_ORIGIN: osionosLocalUrl,
  PUBLIC_OSIONOS_APP_URL: osionosLocalUrl,
});
const appChanged = upsertEnv(osionosEnvPath, {
  VITE_API_URL: process.env.OSIONOS_BRIDGE_PUBLIC_URL ?? 'https://localhost:4000',
  VITE_REQUIRE_BRIDGE_SESSION: 'true',
  VITE_PRISMATICA_URL: prismaticaLocalUrl,
});

const action = rotate ? 'rotated' : 'ensured';
const changed = rootChanged || appChanged;
const keys = [...generatedKeys, 'OSIONOS_APP_URL', 'OSIONOS_ALLOWED_ORIGIN', 'PUBLIC_OSIONOS_APP_URL', 'VITE_API_URL', 'VITE_REQUIRE_BRIDGE_SESSION', 'VITE_PRISMATICA_URL'];
console.log(`${changed ? action : 'already present'}: ${keys.join(', ')}`);