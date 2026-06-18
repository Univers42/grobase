#!/usr/bin/env node
/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   bootstrap-env.mjs                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { createHmac, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const baasDir = resolve(scriptDir, '..');
const repoRoot = resolve(baasDir, '../..');
const target = resolve(baasDir, '.env.local');
const frontendEnv = resolve(repoRoot, 'apps/opposite-osiris/.env.local');

function parseEnv(path) {
	if (!existsSync(path)) return new Map();
	const values = new Map();
	for (const rawLine of readFileSync(path, 'utf8').split(/\r?\n/)) {
		const line = rawLine.trim();
		if (!line || line.startsWith('#') || !line.includes('=')) continue;
		const [key, ...valueParts] = line.split('=');
		let value = valueParts.join('=').trim();
		if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
		values.set(key.trim(), value);
	}
	return values;
}

function base64url(input) {
	return Buffer.from(input).toString('base64url');
}

function signJwt(secret, role) {
	const now = Math.floor(Date.now() / 1000);
	const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
	const payload = base64url(JSON.stringify({ role, iss: 'supabase', iat: now, exp: now + 60 * 60 * 24 * 3650 }));
	const signature = createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url');
	return `${header}.${payload}.${signature}`;
}

function setIfMissing(values, key, value) {
	if (!values.get(key)) values.set(key, value);
}

function writeEnv(path, values, order) {
	mkdirSync(dirname(path), { recursive: true });
	const lines = order.map((key) => [key, values.get(key) ?? ''].join('='));
	writeFileSync(path, `${lines.join('\n')}\n`, { mode: 0o600 });
}

function upsertEnv(path, updates) {
	const existing = parseEnv(path);
	const values = new Map(existing);
	for (const [key, value] of Object.entries(updates)) {
		setIfMissing(values, key, value);
	}
	const preservedKeys = [...values.keys()].filter((key) => !(key in updates)).sort((left, right) => left.localeCompare(right));
	writeEnv(path, values, [...Object.keys(updates), ...preservedKeys]);
}

const existing = parseEnv(target);
const frontend = parseEnv(frontendEnv);
const values = new Map(existing);

for (const key of ['POSTGRES_USER', 'POSTGRES_PASSWORD', 'POSTGRES_DB', 'JWT_SECRET', 'ANON_KEY', 'SERVICE_ROLE_KEY', 'KONG_PUBLIC_API_KEY', 'KONG_SERVICE_API_KEY', 'KONG_ANON_UUID', 'PGRST_DB_ANON_ROLE']) {
	setIfMissing(values, key, frontend.get(key) ?? '');
}

setIfMissing(values, 'ANON_KEY', frontend.get('PUBLIC_BAAS_ANON_KEY') ?? frontend.get('NEXT_PUBLIC_BAAS_ANON_KEY') ?? '');
setIfMissing(values, 'KONG_PUBLIC_API_KEY', frontend.get('PUBLIC_BAAS_ANON_KEY') ?? frontend.get('NEXT_PUBLIC_BAAS_ANON_KEY') ?? '');
setIfMissing(values, 'SERVICE_ROLE_KEY', frontend.get('KONG_SERVICE_API_KEY') ?? '');
setIfMissing(values, 'KONG_SERVICE_API_KEY', frontend.get('SERVICE_ROLE_KEY') ?? '');

setIfMissing(values, 'POSTGRES_USER', 'postgres');
setIfMissing(values, 'POSTGRES_DB', 'postgres');
setIfMissing(values, 'POSTGRES_PASSWORD', randomBytes(24).toString('base64url'));
setIfMissing(values, 'JWT_SECRET', randomBytes(32).toString('hex'));
setIfMissing(values, 'PGRST_DB_ANON_ROLE', 'anon');
setIfMissing(values, 'KONG_ANON_UUID', 'cd4f782c-ac87-5081-b322-b54834d15651');

const jwtSecret = values.get('JWT_SECRET');
setIfMissing(values, 'ANON_KEY', signJwt(jwtSecret, 'anon'));
setIfMissing(values, 'SERVICE_ROLE_KEY', signJwt(jwtSecret, 'service_role'));
setIfMissing(values, 'KONG_PUBLIC_API_KEY', values.get('ANON_KEY'));
setIfMissing(values, 'KONG_SERVICE_API_KEY', values.get('SERVICE_ROLE_KEY'));

const user = values.get('POSTGRES_USER');
const password = values.get('POSTGRES_PASSWORD');
const db = values.get('POSTGRES_DB');
const databaseUrl = `postgres://${encodeURIComponent(user)}:${encodeURIComponent(password)}@postgres:5432/${encodeURIComponent(db)}`;
values.set('DATABASE_URL', databaseUrl);
values.set('PGRST_DB_URI', databaseUrl);
setIfMissing(values, 'PROJECT_INIT_MARKER', 'track_binocle_20260504');
values.set('GOTRUE_DB_DATABASE_URL', databaseUrl);
setIfMissing(values, 'GOTRUE_JWT_SECRET', values.get('JWT_SECRET'));
setIfMissing(values, 'PGRST_JWT_SECRET', values.get('JWT_SECRET'));
setIfMissing(values, 'PG_META_DB_HOST', 'postgres');
setIfMissing(values, 'PG_META_DB_PORT', '5432');
setIfMissing(values, 'PG_META_DB_NAME', values.get('POSTGRES_DB'));
setIfMissing(values, 'PG_META_DB_USER', values.get('POSTGRES_USER'));
values.set('PG_META_DB_PASSWORD', values.get('POSTGRES_PASSWORD'));
setIfMissing(values, 'SECRET_KEY_BASE', randomBytes(48).toString('base64url'));
setIfMissing(values, 'VAULT_ENC_KEY', randomBytes(16).toString('hex'));
setIfMissing(values, 'GOTRUE_SMTP_HOST', frontend.get('SMTP_HOST') ?? 'mailpit');
setIfMissing(values, 'GOTRUE_SMTP_PORT', frontend.get('SMTP_PORT') ?? '1025');
setIfMissing(values, 'GOTRUE_SMTP_USER', frontend.get('SMTP_USERNAME') ?? '');
setIfMissing(values, 'GOTRUE_SMTP_PASS', frontend.get('SMTP_PASSWORD') ?? '');
setIfMissing(values, 'GOTRUE_SMTP_ADMIN_EMAIL', frontend.get('SMTP_FROM_ADDRESS') ?? 'noreply@mini-baas.local');
setIfMissing(values, 'GOTRUE_SMTP_SENDER_NAME', frontend.get('SMTP_FROM_NAME') ?? 'Prismatica');
setIfMissing(values, 'GOTRUE_SITE_URL', frontend.get('PUBLIC_SITE_URL') ?? 'https://localhost:4322');
setIfMissing(values, 'GOTRUE_URI_ALLOW_LIST', 'https://localhost:4322/**,https://localhost:3001/**,http://localhost:4322/**,http://localhost:3001/**,http://localhost:4321/**,https://localhost:4321/**,http://localhost:5173/**,https://localhost:5173/**');

const order = [
	'POSTGRES_USER',
	'POSTGRES_PASSWORD',
	'POSTGRES_DB',
	'DATABASE_URL',
	'PGRST_DB_URI',
	'PGRST_DB_ANON_ROLE',
	'JWT_SECRET',
	'ANON_KEY',
	'SERVICE_ROLE_KEY',
	'KONG_PUBLIC_API_KEY',
	'KONG_SERVICE_API_KEY',
	'KONG_ANON_UUID',
	'PROJECT_INIT_MARKER',
	'GOTRUE_DB_DATABASE_URL',
	'GOTRUE_JWT_SECRET',
	'PGRST_JWT_SECRET',
	'PG_META_DB_HOST',
	'PG_META_DB_PORT',
	'PG_META_DB_NAME',
	'PG_META_DB_USER',
	'PG_META_DB_PASSWORD',
	'SECRET_KEY_BASE',
	'VAULT_ENC_KEY',
	'GOTRUE_SMTP_HOST',
	'GOTRUE_SMTP_PORT',
	'GOTRUE_SMTP_USER',
	'GOTRUE_SMTP_PASS',
	'GOTRUE_SMTP_ADMIN_EMAIL',
	'GOTRUE_SMTP_SENDER_NAME',
	'GOTRUE_SITE_URL',
	'GOTRUE_URI_ALLOW_LIST',
];

writeEnv(target, values, order);
console.log(`Wrote ${target}`);

upsertEnv(frontendEnv, {
	PUBLIC_BAAS_URL: '/api',
	PUBLIC_AUTH_GATEWAY_URL: '/api/auth',
	PUBLIC_BAAS_ANON_KEY: values.get('KONG_PUBLIC_API_KEY'),
	PUBLIC_SITE_URL: 'https://localhost:4322',
	ASTRO_DEV_HOST: '0.0.0.0',
	ASTRO_DEV_PORT: '4322',
	ASTRO_DEV_HTTPS: 'false',
	PUBLIC_OSIONOS_APP_URL: 'https://localhost:3001',
	PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION: 'false',
	AUTH_REQUIRE_EMAIL_VERIFICATION: 'false',
	GOTRUE_MAILER_AUTOCONFIRM: 'true',
	PUBLIC_TURNSTILE_SITE_KEY: '',
	TURNSTILE_SECRET_KEY: '',
	TURNSTILE_BYPASS_LOCAL: 'true',
});
console.log(`Wrote ${frontendEnv}`);
