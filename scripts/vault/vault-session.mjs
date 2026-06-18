#!/usr/bin/env node
/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   vault-session.mjs                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '../../..');
const command = process.argv[2] ?? 'help';

const localEnv = readLocalEnv();

function parseEnv(filePath) {
  const values = new Map();
  if (!existsSync(filePath)) return values;
  for (const rawLine of readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const match = /^\s*(?:export\s+)?([A-Za-z_]\w*)\s*=\s*(.*)$/.exec(rawLine);
    if (!match) continue;
    let value = match[2].replace(/\r$/, '');
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    values.set(match[1], value);
  }
  return values;
}

function readLocalEnv() {
  const values = new Map();
  for (const relativePath of ['.env.local', '.env', 'apps/baas/.env.local', 'apps/baas/mini-baas-infra/.env']) {
    for (const [key, value] of parseEnv(resolve(repoRoot, relativePath)).entries()) {
      if (value && !values.has(key)) values.set(key, value);
    }
  }
  return values;
}

function option(key, fallback = '') {
  return process.env[key] || localEnv.get(key) || fallback;
}

function expandHome(filePath) {
  if (filePath === '~') return homedir();
  if (filePath.startsWith('~/')) return resolve(homedir(), filePath.slice(2));
  return filePath;
}

function absolute(filePath) {
  const expanded = expandHome(filePath);
  return expanded.startsWith('/') ? expanded : resolve(repoRoot, expanded);
}

function displayPath(filePath) {
  const absolutePath = absolute(filePath);
  const prefix = `${repoRoot}/`;
  return absolutePath.startsWith(prefix) ? absolutePath.slice(prefix.length) : absolutePath;
}

function serialize(key, value) {
  const text = value === undefined || value === null ? '' : String(value);
  if (text === '') return `${key}=`;
  if (/\s|#/.test(text)) return `${key}=${JSON.stringify(text)}`;
  return `${key}=${text}`;
}

const flyVaultApp = option('FLY_VAULT_APP', 'track-binocle-vault');
const vaultAddr = option('VAULT_ADDR', option('FLY_VAULT_URL', `https://${flyVaultApp}.fly.dev`));
const vaultNamespace = option('VAULT_NAMESPACE', '');
const envPrefix = option('VAULT_ENV_PREFIX', 'secret/data/track-binocle/env');
const sessionFile = option('VAULT_SESSION_FILE', '.vault/track-binocle-session.env');
const adminTokenFile = option('VAULT_ADMIN_TOKEN_FILE', '.vault/track-binocle-admin.env');
const cliTokenFile = option('VAULT_CLI_TOKEN_FILE', '~/.vault-token');
const writeCliToken = option('VAULT_WRITE_CLI_TOKEN', 'true') !== 'false';

class SessionError extends Error {
  constructor(message) {
    super(message);
    this.name = 'SessionError';
  }
}

function sanitizeOutput(text) {
  let sanitized = String(text ?? '');
  for (const secretValue of [option('FLY_API_TOKEN', ''), process.env.VAULT_TOKEN ?? '', process.env.VAULT_API_KEY ?? '']) {
    if (secretValue) sanitized = sanitized.split(secretValue).join('[redacted]');
  }
  return sanitized
    .replace(/\b(hvs|hvb|s)\.[A-Za-z0-9._-]+/g, '[vault-token-redacted]')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 600);
}

function ensurePrivateFile(filePath) {
  if (!existsSync(filePath)) return;
  const mode = statSync(filePath).mode & 0o777;
  if ((mode & 0o077) !== 0) {
    throw new SessionError(`[vault-session] refusing ${displayPath(filePath)} because it must be private; run: chmod 600 ${displayPath(filePath)}`);
  }
}

function readTokenFile(filePath) {
  const absolutePath = absolute(filePath);
  if (!existsSync(absolutePath)) return undefined;
  ensurePrivateFile(absolutePath);
  const text = readFileSync(absolutePath, 'utf8').trim();
  if (!text) return undefined;
  const values = parseEnv(absolutePath);
  return values.get('VAULT_TOKEN') || values.get('VAULT_API_KEY') || text.split(/\r?\n/)[0].trim();
}

function tokenSources() {
  const sources = [
    ...(process.env.VAULT_TOKEN ? [{ source: 'VAULT_TOKEN', token: process.env.VAULT_TOKEN }] : []),
    ...(process.env.VAULT_API_KEY ? [{ source: 'VAULT_API_KEY', token: process.env.VAULT_API_KEY }] : []),
    { source: sessionFile, token: readTokenFile(sessionFile) },
    ...(process.env.VAULT_TOKEN_FILE ? [{ source: process.env.VAULT_TOKEN_FILE, token: readTokenFile(process.env.VAULT_TOKEN_FILE) }] : []),
    { source: adminTokenFile, token: readTokenFile(adminTokenFile) },
    { source: cliTokenFile, token: readTokenFile(cliTokenFile) },
  ];
  return sources.filter((item) => item.token);
}

function activeToken() {
  const [first] = tokenSources();
  if (!first) throw new SessionError('[vault-session] no Vault session token found; run make vault-login-user, vault-login-fly-admin, vault-login-approle, or vault-login-jwt');
  return first;
}

function writeTokenEnv(filePath, token, source, extra = {}) {
  const absolutePath = absolute(filePath);
  mkdirSync(dirname(absolutePath), { recursive: true, mode: 0o700 });
  const lines = [
    '# Track Binocle Vault session token. Keep this file private.',
    serialize('VAULT_ADDR', vaultAddr),
    serialize('VAULT_TOKEN', token),
    serialize('VAULT_ENV_PREFIX', envPrefix),
    serialize('VAULT_SESSION_SOURCE', source),
    serialize('VAULT_SESSION_CREATED_AT', new Date().toISOString()),
  ];
  if (vaultNamespace) lines.push(serialize('VAULT_NAMESPACE', vaultNamespace));
  for (const [key, value] of Object.entries(extra)) lines.push(serialize(key, value));
  lines.push('');
  writeFileSync(absolutePath, lines.join('\n'), { mode: 0o600 });
  chmodSync(absolutePath, 0o600);
  console.log(`[vault-session] wrote ${displayPath(absolutePath)}`);
}

function writeCliTokenFile(token) {
  if (!writeCliToken) return;
  const absolutePath = absolute(cliTokenFile);
  mkdirSync(dirname(absolutePath), { recursive: true, mode: 0o700 });
  writeFileSync(absolutePath, `${token}\n`, { mode: 0o600 });
  chmodSync(absolutePath, 0o600);
  console.log(`[vault-session] wrote ${displayPath(absolutePath)}`);
}

function saveSession(token, source, extra = {}) {
  writeTokenEnv(sessionFile, token, source, extra);
  writeCliTokenFile(token);
}

function saveAdminSession(token, source, extra = {}) {
  writeTokenEnv(adminTokenFile, token, source, extra);
  saveSession(token, source, extra);
}

async function vaultRequest(method, path, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['X-Vault-Token'] = token;
  if (vaultNamespace) headers['X-Vault-Namespace'] = vaultNamespace;
  let response;
  try {
    response = await fetch(`${vaultAddr.replace(/\/$/, '')}/v1/${path.replace(/^\//, '')}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (error) {
    const cause = error?.cause ?? error;
    throw new SessionError(`[vault-session] could not reach Vault at ${vaultAddr}: ${cause?.message ?? String(error)}`);
  }
  if (!response.ok) {
    let detail = await response.text();
    try {
      const payload = JSON.parse(detail);
      if (Array.isArray(payload.errors)) detail = payload.errors.join('; ');
    } catch {
      detail = detail.replace(/\s+/g, ' ').trim();
    }
    const suffix = detail ? `: ${detail}` : '';
    throw new SessionError(`[vault-session] Vault ${method} ${path} failed with HTTP ${response.status}${suffix}`);
  }
  if (response.status === 204) return {};
  return response.json();
}

function run(commandName, args, { input, env = {}, capture = true } = {}) {
  const result = spawnSync(commandName, args, {
    cwd: repoRoot,
    input,
    encoding: 'utf8',
    env: { ...process.env, ...env },
    maxBuffer: 1024 * 1024 * 10,
    stdio: capture ? ['pipe', 'pipe', 'pipe'] : 'inherit',
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const detail = sanitizeOutput(`${result.stderr ?? ''} ${result.stdout ?? ''}`);
    const suffix = detail ? `: ${detail}` : '';
    throw new SessionError(`[vault-session] ${commandName} ${args.join(' ')} failed with exit ${result.status}${suffix}`);
  }
  return result.stdout ?? '';
}

function commandExists(commandName) {
  const result = spawnSync('sh', ['-lc', `command -v ${JSON.stringify(commandName)} >/dev/null 2>&1`]);
  return result.status === 0;
}

function githubToken() {
  const token = option('VAULT_GITHUB_TOKEN', option('GITHUB_TOKEN', ''));
  if (token) return token;
  if (!commandExists('gh')) throw new SessionError('[vault-session] GitHub auth requires GITHUB_TOKEN, VAULT_GITHUB_TOKEN, or gh auth token');
  return run('gh', ['auth', 'token']).trim();
}

async function loginGithub() {
  const authPath = option('VAULT_GITHUB_AUTH_PATH', 'github');
  const payload = await vaultRequest('POST', `auth/${authPath}/login`, { token: githubToken() });
  const token = payload?.auth?.client_token;
  if (!token) throw new SessionError('[vault-session] GitHub login did not return a Vault token');
  saveSession(token, `github:${authPath}`, { VAULT_AUTH_METHOD: 'github' });
}

async function loginOidc() {
  const vaultCli = option('VAULT_CLI', 'vault');
  if (!commandExists(vaultCli)) throw new SessionError('[vault-session] OIDC browser login requires the Vault CLI; install vault or use VAULT_USER_AUTH_METHOD=github');
  const args = ['login', '-method=oidc', '-format=json'];
  const role = option('VAULT_OIDC_ROLE', '');
  if (role) args.push(`role=${role}`);
  const result = spawnSync(vaultCli, args, {
    cwd: repoRoot,
    env: { ...process.env, VAULT_ADDR: vaultAddr, VAULT_NAMESPACE: vaultNamespace },
    encoding: 'utf8',
    stdio: ['inherit', 'pipe', 'inherit'],
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new SessionError(`[vault-session] ${vaultCli} ${args.join(' ')} failed with exit ${result.status}`);
  const output = result.stdout ?? '';
  const payload = JSON.parse(output);
  const token = payload?.auth?.client_token;
  if (!token) throw new SessionError('[vault-session] OIDC login did not return a Vault token');
  saveSession(token, 'oidc', { VAULT_AUTH_METHOD: 'oidc' });
}

async function loginUser() {
  const method = option('VAULT_USER_AUTH_METHOD', 'github');
  if (method === 'github') return loginGithub();
  if (method === 'oidc') return loginOidc();
  throw new SessionError('[vault-session] VAULT_USER_AUTH_METHOD must be github or oidc');
}

async function loginAppRole() {
  const authPath = option('VAULT_APPROLE_AUTH_PATH', 'approle');
  const roleIdFile = option('VAULT_ROLE_ID_FILE', '.vault/track-binocle-role-id');
  const secretIdFile = option('VAULT_SECRET_ID_FILE', '.vault/track-binocle-secret-id');
  const roleId = option('VAULT_ROLE_ID', existsSync(absolute(roleIdFile)) ? readFileSync(absolute(roleIdFile), 'utf8').trim() : '');
  const secretId = option('VAULT_SECRET_ID', existsSync(absolute(secretIdFile)) ? readFileSync(absolute(secretIdFile), 'utf8').trim() : '');
  if (!roleId || !secretId) throw new SessionError(`[vault-session] AppRole login requires VAULT_ROLE_ID/VAULT_SECRET_ID or ${displayPath(roleIdFile)} and ${displayPath(secretIdFile)}`);
  const payload = await vaultRequest('POST', `auth/${authPath}/login`, { role_id: roleId, secret_id: secretId });
  const token = payload?.auth?.client_token;
  if (!token) throw new SessionError('[vault-session] AppRole login did not return a Vault token');
  saveSession(token, `approle:${authPath}`, { VAULT_AUTH_METHOD: 'approle' });
}

async function loginJwt() {
  const authPath = option('VAULT_JWT_AUTH_PATH', option('VAULT_GITHUB_OIDC_AUTH_PATH', 'jwt'));
  const role = option('VAULT_JWT_ROLE', option('VAULT_GITHUB_OIDC_ROLE', 'track-binocle-github-actions'));
  const jwtTokenFile = option('VAULT_JWT_TOKEN_FILE', '');
  const jwt = option('JWT_TOKEN', option('VAULT_JWT_TOKEN', jwtTokenFile ? readFileSync(absolute(jwtTokenFile), 'utf8').trim() : ''));
  if (!jwt) throw new SessionError('[vault-session] JWT login requires JWT_TOKEN, VAULT_JWT_TOKEN, or VAULT_JWT_TOKEN_FILE');
  const payload = await vaultRequest('POST', `auth/${authPath}/login`, { role, jwt });
  const token = payload?.auth?.client_token;
  if (!token) throw new SessionError('[vault-session] JWT login did not return a Vault token');
  saveSession(token, `jwt:${authPath}:${role}`, { VAULT_AUTH_METHOD: 'jwt', VAULT_JWT_ROLE: role });
}

function flyCommand() {
  const flyBin = option('FLY_BIN', '');
  const flyApiToken = option('FLY_API_TOKEN', '');
  if (flyBin) return { commandName: flyBin, args: [], env: { FLY_API_TOKEN: flyApiToken } };
  if (commandExists('flyctl')) return { commandName: 'flyctl', args: [], env: { FLY_API_TOKEN: flyApiToken } };
  if (commandExists('fly')) return { commandName: 'fly', args: [], env: { FLY_API_TOKEN: flyApiToken } };
  if (flyApiToken) return { commandName: 'docker', args: ['compose', '--profile', 'secrets', 'run', '--rm', '--no-deps', '-e', 'FLY_API_TOKEN', 'vault-fly'], env: { FLY_API_TOKEN: flyApiToken } };
  throw new SessionError('[vault-session] Fly admin login requires flyctl/fly or FLY_API_TOKEN in the shell or ignored env file');
}

function flyRootToken() {
  const fly = flyCommand();
  const output = run(fly.commandName, [...fly.args, 'ssh', 'console', '--app', flyVaultApp, '--command', 'jq -r .root_token /vault/data/.vault-keys.json'], { env: fly.env });
  const token = output.split(/\r?\n/).map((line) => line.trim()).find((line) => /^(hvs|hvb|s)\./.test(line));
  if (!token) throw new SessionError('[vault-session] Fly admin login could not read a Vault root token from the Fly volume');
  return token;
}

async function loginFlyAdmin() {
  const rootToken = flyRootToken();
  const ttl = option('VAULT_ADMIN_TOKEN_TTL', '2h');
  const payload = await vaultRequest('POST', 'auth/token/create', {
    policies: ['admin'],
    ttl,
    renewable: false,
    metadata: {
      project: 'track-binocle',
      source: 'fly-admin-session',
    },
  }, rootToken);
  const token = payload?.auth?.client_token;
  if (!token) throw new SessionError('[vault-session] Fly admin login did not return an admin child token');
  saveAdminSession(token, 'fly-admin', { VAULT_AUTH_METHOD: 'fly-admin', VAULT_ADMIN_TOKEN_TTL: ttl });
}

// Strip control characters (CR/LF/tabs/etc.) before logging values that come
// from the Vault server response, so a forged token field cannot inject extra
// log lines (jssecurity:S5145 — log injection).
function logSafe(value) {
  return String(value).replace(/[\u0000-\u001f\u007f]/g, ' ');
}

async function sessionStatus() {
  const { source, token } = activeToken();
  const payload = await vaultRequest('GET', 'auth/token/lookup-self', undefined, token);
  const data = payload?.data ?? {};
  console.log(`[vault-session] vault address: ${vaultAddr}`);
  console.log(`[vault-session] namespace: ${vaultNamespace || '<none>'}`);
  console.log(`[vault-session] token source: ${source}`);
  console.log(`[vault-session] display name: ${logSafe(data.display_name ?? '<unknown>')}`);
  console.log(`[vault-session] policies: ${logSafe((data.policies ?? []).join(', ') || '<none>')}`);
  console.log(`[vault-session] ttl: ${logSafe(data.ttl ?? '<unknown>')}`);
  console.log(`[vault-session] renewable: ${data.renewable === true ? 'true' : 'false'}`);
}

function runVaultEnv(commandName) {
  const { token } = activeToken();
  const result = spawnSync(process.execPath, ['apps/baas/scripts/vault-env.mjs', commandName], {
    cwd: repoRoot,
    env: { ...process.env, VAULT_ADDR: vaultAddr, VAULT_NAMESPACE: vaultNamespace, VAULT_TOKEN: token, VAULT_ENV_PREFIX: envPrefix },
    stdio: 'inherit',
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new SessionError(`[vault-session] vault-env ${commandName} failed with exit ${result.status}`);
}

function fetchManagedSecrets() {
  runVaultEnv('fetch');
}

function mintTeamToken() {
  const { token } = activeToken();
  const role = option('VAULT_TEAM_ROLE', 'reader');
  const ttl = option('VAULT_TOKEN_TTL', role === 'writer' ? '8h' : '24h');
  const tokenFile = option('VAULT_TEAM_TOKEN_FILE', `.vault/track-binocle-${role}.env`);
  const result = spawnSync(process.execPath, ['apps/baas/scripts/vault-env.mjs', 'team-token'], {
    cwd: repoRoot,
    env: {
      ...process.env,
      VAULT_ADDR: vaultAddr,
      VAULT_NAMESPACE: vaultNamespace,
      VAULT_TOKEN: token,
      VAULT_ENV_PREFIX: envPrefix,
      VAULT_TEAM_ROLE: role,
      VAULT_TOKEN_TTL: ttl,
      VAULT_TEAM_TOKEN_FILE: tokenFile,
      VAULT_PUBLIC_ADDR: vaultAddr,
    },
    stdio: 'inherit',
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new SessionError(`[vault-session] token mint failed with exit ${result.status}`);
}

async function exportSecret() {
  const secretPath = option('VAULT_SECRET_PATH', '');
  if (!secretPath) {
    fetchManagedSecrets();
    return;
  }
  const { token } = activeToken();
  const outputFile = option('VAULT_SECRET_OUTPUT', '.vault/track-binocle-secret.json');
  const payload = await vaultRequest('GET', secretPath, undefined, token);
  const data = payload?.data?.data ?? payload?.data ?? payload;
  const absoluteOutput = absolute(outputFile);
  mkdirSync(dirname(absoluteOutput), { recursive: true, mode: 0o700 });
  writeFileSync(absoluteOutput, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
  console.log(`[vault-session] wrote ${displayPath(absoluteOutput)}`);
}

async function logout() {
  const sources = tokenSources();
  const [current] = sources;
  if (current) {
    try {
      await vaultRequest('POST', 'auth/token/revoke-self', {}, current.token);
      console.log('[vault-session] revoked active Vault token');
    } catch (error) {
      console.warn(error instanceof Error ? error.message : String(error));
    }
  }
  for (const filePath of [sessionFile, cliTokenFile]) {
    const absolutePath = absolute(filePath);
    if (existsSync(absolutePath)) {
      rmSync(absolutePath);
      console.log(`[vault-session] removed ${displayPath(absolutePath)}`);
    }
  }
  const absoluteAdmin = absolute(adminTokenFile);
  const shouldRemoveAdmin = option('VAULT_LOGOUT_REMOVE_ADMIN', 'false') === 'true' || (current && readTokenFile(adminTokenFile) === current.token);
  if (shouldRemoveAdmin && existsSync(absoluteAdmin)) {
    rmSync(absoluteAdmin);
    console.log(`[vault-session] removed ${displayPath(absoluteAdmin)}`);
  }
}

function check() {
  console.log(`[vault-session] vault address: ${vaultAddr}`);
  console.log(`[vault-session] namespace: ${vaultNamespace || '<none>'}`);
  console.log(`[vault-session] env prefix: ${envPrefix}`);
  console.log(`[vault-session] session file: ${displayPath(sessionFile)}`);
  console.log(`[vault-session] admin file: ${displayPath(adminTokenFile)}`);
  console.log(`[vault-session] cli token file: ${displayPath(cliTokenFile)}`);
  console.log(`[vault-session] node: ${process.version}`);
  console.log(`[vault-session] vault CLI: ${commandExists(option('VAULT_CLI', 'vault')) ? 'present' : 'missing'}`);
  console.log(`[vault-session] gh CLI: ${commandExists('gh') ? 'present' : 'missing'}`);
  console.log(`[vault-session] fly CLI: ${commandExists('flyctl') || commandExists('fly') ? 'present' : 'missing'}`);
  console.log(`[vault-session] FLY_API_TOKEN: ${option('FLY_API_TOKEN', '') ? 'available' : 'missing'}`);
  const sources = tokenSources().map((item) => item.source);
  console.log(`[vault-session] active token source: ${sources[0] ?? '<none>'}`);
}

function help() {
  console.log('Usage: node apps/baas/scripts/vault-session.mjs <check|login-user|login-approle|login-jwt|login-fly-admin|status|fetch|team-token|export-secret|logout>');
}

async function main() {
  if (command === 'check') return check();
  if (command === 'login-user') return loginUser();
  if (command === 'login-approle') return loginAppRole();
  if (command === 'login-jwt') return loginJwt();
  if (command === 'login-fly-admin') return loginFlyAdmin();
  if (command === 'status') return sessionStatus();
  if (command === 'fetch') return fetchManagedSecrets();
  if (command === 'team-token') return mintTeamToken();
  if (command === 'export-secret') return exportSecret();
  if (command === 'logout') return logout();
  help();
}

try {
  await main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}