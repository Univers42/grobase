/**
 * mini-BaaS Observatory — Interactive Real-Time Log Stream + Health Matrix
 *
 * Modes:
 *   interactive (default)  Full CLI with live prompt. Filter logs, show
 *                          health, clear screen — all without stopping the
 *                          stream.
 *   headless               Background daemon. Logs to stdout, PID written
 *                          to .observatory.pid for `make kill-watch`.
 *   logs                   Stream-only, no interactive prompt.
 *
 * Usage:
 *   npx ts-node -r tsconfig-paths/register tools/observatory.ts
 *   npx ts-node -r tsconfig-paths/register tools/observatory.ts --headless
 *   npx ts-node -r tsconfig-paths/register tools/observatory.ts --logs
 *
 * Requires: Docker socket access (/var/run/docker.sock)
 */

import { execFileSync, spawn } from 'node:child_process';
import { createInterface, Interface as RLInterface } from 'node:readline';
import * as fs from 'node:fs';
import * as path from 'node:path';
import {
	Observable,
	Subject,
	Subscription,
	EMPTY,
} from 'rxjs';
import {
	catchError,
	takeUntil,
	finalize,
} from 'rxjs/operators';

// ─── Configuration ──────────────────────────────────────────────────────────

const COMPOSE_PROJECT = 'mini-baas';
const PID_FILE = path.resolve(__dirname, '../../.observatory.pid');
const DOCKER_EXECUTABLE = '/usr/bin/docker';

// eslint-disable-next-line no-control-regex
const ANSI_ESCAPE_RE = /\x1b\[[0-9;]*m/g;

function safeString(value: unknown, fallback = ''): string {
	if (value == null) return fallback;
	if (typeof value === 'string') return value;
	if (typeof value === 'number' || typeof value === 'boolean' || typeof value === 'bigint') {
		return String(value);
	}
	if (typeof value === 'symbol') return value.description ?? fallback;
	try {
		return JSON.stringify(value) ?? fallback;
	} catch {
		return fallback;
	}
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
	return value && typeof value === 'object' ? value as Record<string, unknown> : undefined;
}

// ─── Modes ──────────────────────────────────────────────────────────────────

type Mode = 'interactive' | 'headless' | 'logs';

function resolveMode(): Mode {
	const args = new Set(process.argv.slice(2));
	if (args.has('--headless')) return 'headless';
	if (args.has('--logs') || args.has('--logs-only')) return 'logs';
	return 'interactive';
}

// ─── Service Discovery ─────────────────────────────────────────────────────

function getActiveServices(): string[] {
	try {
		return execFileSync(DOCKER_EXECUTABLE, ['compose', 'config', '--services'], {
			encoding: 'utf-8',
			timeout: 10_000,
		})
			.trim()
			.split('\n')
			.filter(Boolean);
	} catch {
		return [
			'waf', 'kong', 'gotrue', 'postgres', 'postgrest', 'mongo',
			'mongo-api', 'adapter-registry', 'query-router', 'email-service',
			'permission-engine', 'schema-service', 'realtime', 'redis',
			'vault', 'vault-init', 'db-bootstrap', 'mongo-keyfile', 'mongo-init',
		];
	}
}

let SERVICES: string[] = [];

function isKnownService(s: string): boolean {
	return SERVICES.includes(s);
}

// ─── ANSI Helpers ───────────────────────────────────────────────────────────

const RESET = '\x1b[0m';
const BOLD = '\x1b[1m';
const DIM = '\x1b[2m';
const RED = '\x1b[31m';
const GREEN = '\x1b[32m';
const YELLOW = '\x1b[33m';
const BLUE = '\x1b[34m';
const MAGENTA = '\x1b[35m';
const CYAN = '\x1b[36m';
const WHITE = '\x1b[37m';
const BRIGHT_RED = '\x1b[91m';
const BRIGHT_GREEN = '\x1b[92m';
const BRIGHT_YELLOW = '\x1b[93m';
const BRIGHT_BLUE = '\x1b[94m';
const BRIGHT_MAGENTA = '\x1b[95m';
const BRIGHT_CYAN = '\x1b[96m';

const PALETTE = [
	CYAN, GREEN, YELLOW, MAGENTA, BLUE, BRIGHT_CYAN, BRIGHT_GREEN,
	BRIGHT_YELLOW, BRIGHT_MAGENTA, BRIGHT_BLUE, WHITE, BRIGHT_RED,
];

function colorFor(service: string): string {
	const idx = SERVICES.indexOf(service);
	const i = idx >= 0 ? idx : hashCode(service);
	return PALETTE[Math.abs(i) % PALETTE.length];
}

function hashCode(s: string): number {
	let h = 0;
	for (const character of s) {
		h = Math.trunc(Math.imul(31, h) + (character.codePointAt(0) ?? 0));
	}
	return h;
}

function pad(s: string, len: number): string {
	return s.length >= len ? s.substring(0, len) : s + ' '.repeat(len - s.length);
}

function timestamp(): string {
	return new Date().toLocaleTimeString('en-GB', { hour12: false });
}

/** Strip ANSI escape codes for visible-length measurement. */
function stripAnsi(s: string): string {
	return s.replaceAll(ANSI_ESCAPE_RE, '');
}

/** Pad a (possibly ANSI-colored) string to `width` visible characters. */
function vpad(s: string, width: number): string {
	const vis = stripAnsi(s).length;
	return vis >= width ? s : s + ' '.repeat(width - vis);
}

// ─── Docker helpers ─────────────────────────────────────────────────────────

interface ContainerInfo {
	id: string;
	name: string;
	service: string;
	status: string;
	health: string;
	startedAt: string;
}

function listContainers(): ContainerInfo[] {
	try {
		const raw = execFileSync(
			DOCKER_EXECUTABLE,
			[
				'ps',
				'-a',
				'--filter', `label=com.docker.compose.project=${COMPOSE_PROJECT}`,
				'--format', '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.service"}}|{{.Status}}|{{.State}}',
			],
			{ encoding: 'utf-8', timeout: 10_000 },
		).trim();

		if (!raw) return [];

		return raw.split('\n').map((line) => {
			const [id = '', name = '', service = '', status = '', state = ''] = line.split('|');
			let health = 'unknown';
			if (status.includes('(healthy)')) health = 'healthy';
			else if (status.includes('(unhealthy)')) health = 'unhealthy';
			else if (status.includes('(health: starting)')) health = 'starting';
			else if (state === 'running') health = 'running';
			else if (state === 'exited') health = 'exited';
			else if (state === 'created') health = 'created';

			const startedAt = statusWithoutHealth(status);
			return {
				id: id.trim(), name: name.trim(), service: service.trim(),
				status: status.trim(), health, startedAt: startedAt.trim(),
			};
		});
	} catch {
		return [];
	}
}

function statusWithoutHealth(status: string): string {
	const parenthesisIndex = status.indexOf('(');
	return parenthesisIndex >= 0 ? status.slice(0, parenthesisIndex).trimEnd() : status;
}

// ─── Log entry ──────────────────────────────────────────────────────────────

interface LogEntry {
	service: string;
	stream: 'stdout' | 'stderr';
	message: string;
	timestamp: string;
}

// ─── Observable: Container log stream ───────────────────────────────────────

function containerLogs$(containerId: string, service: string): Observable<LogEntry> {
	return new Observable<LogEntry>((subscriber) => {
		const proc = spawn(DOCKER_EXECUTABLE, ['logs', '--follow', '--tail', '50', containerId], {
			stdio: ['ignore', 'pipe', 'pipe'],
		});

		const processLine = (data: Buffer, stream: 'stdout' | 'stderr') => {
			const lines = data.toString('utf-8').split('\n');
			for (const raw of lines) {
				const line = raw.trim();
				if (!line) continue;
				subscriber.next({ service, stream, message: line, timestamp: timestamp() });
			}
		};

		proc.stdout?.on('data', (d: Buffer) => processLine(d, 'stdout'));
		proc.stderr?.on('data', (d: Buffer) => processLine(d, 'stderr'));
		proc.on('close', () => subscriber.complete());
		proc.on('error', (err) => subscriber.error(err));

		return () => { proc.kill('SIGTERM'); };
	});
}

// ─── Observable: Docker events ──────────────────────────────────────────────

interface DockerEvent {
	type: 'start' | 'stop' | 'die' | 'create';
	containerId: string;
	service: string;
}

function dockerEvents$(): Observable<DockerEvent> {
	return new Observable<DockerEvent>((subscriber) => {
		const proc = spawn(
			DOCKER_EXECUTABLE,
			[
				'events',
				'--filter', `label=com.docker.compose.project=${COMPOSE_PROJECT}`,
				'--filter', 'type=container',
				'--filter', 'event=start',
				'--filter', 'event=stop',
				'--filter', 'event=die',
				'--format', '{{.Status}}|{{.ID}}|{{.Actor.Attributes.com.docker.compose.service}}',
			],
			{ stdio: ['ignore', 'pipe', 'pipe'] },
		);

		proc.stdout?.on('data', (data: Buffer) => {
			for (const raw of data.toString().split('\n')) {
				const line = raw.trim();
				if (!line) continue;
				const [status = '', id = '', svc = ''] = line.split('|');
				const type = status as DockerEvent['type'];
				if (['start', 'stop', 'die'].includes(type)) {
					subscriber.next({ type, containerId: id.substring(0, 12), service: svc });
				}
			}
		});

		proc.on('close', () => subscriber.complete());
		proc.on('error', (err) => subscriber.error(err));
		return () => proc.kill('SIGTERM');
	});
}

// ─── Health Matrix ──────────────────────────────────────────────────────────

const HEALTH_SERVICE_WIDTH = 20;
const HEALTH_STATUS_WIDTH = 14;
const HEALTH_UPTIME_WIDTH = 26;
const HEALTH_INNER_WIDTH = HEALTH_SERVICE_WIDTH + HEALTH_STATUS_WIDTH + HEALTH_UPTIME_WIDTH + 8;
const HEALTH_BORDER = `${CYAN}│${RESET}`;
const UP_HEALTH_STATES = new Set(['healthy', 'running', 'starting']);
const EXITED_STATUS_RE = /Exited\s*\((\d+)\)/;

interface HealthDisplay {
	statusCol: string;
	uptimeCol: string;
}

function healthColumnRow(service: string, status: string, uptime: string): string {
	return `${HEALTH_BORDER} ${vpad(service, HEALTH_SERVICE_WIDTH)} ${HEALTH_BORDER} ${vpad(status, HEALTH_STATUS_WIDTH)} ${HEALTH_BORDER} ${vpad(uptime, HEALTH_UPTIME_WIDTH)} ${HEALTH_BORDER}`;
}

function healthFullRule(left: string, right: string): string {
	return `${CYAN}${left}${'─'.repeat(HEALTH_INNER_WIDTH)}${right}${RESET}`;
}

function healthColumnRule(left: string, middle: string, right: string): string {
	return `${CYAN}${left}${'─'.repeat(HEALTH_SERVICE_WIDTH + 2)}${middle}${'─'.repeat(HEALTH_STATUS_WIDTH + 2)}${middle}${'─'.repeat(HEALTH_UPTIME_WIDTH + 2)}${right}${RESET}`;
}

function healthHeaderRows(): string[] {
	const titleText = `${BOLD}${WHITE}mini-BaaS Health Matrix${RESET}`;
	const tsText = `${DIM}${timestamp()}${RESET}`;
	const titleGap = HEALTH_INNER_WIDTH - 2 - stripAnsi(titleText).length - stripAnsi(tsText).length;
	return [
		healthFullRule('┌', '┐'),
		`${HEALTH_BORDER} ${titleText}${' '.repeat(Math.max(1, titleGap))}${tsText} ${HEALTH_BORDER}`,
		healthColumnRule('├', '┬', '┤'),
		healthColumnRow(
			`${BOLD}Service${RESET}`,
			`${BOLD}Status${RESET}`,
			`${BOLD}Uptime${RESET}`,
		),
		healthColumnRule('├', '┼', '┤'),
	];
}

function exitedDisplay(container: ContainerInfo): HealthDisplay {
	const exitMatch = EXITED_STATUS_RE.exec(container.status);
	const exitCode = Number.parseInt(exitMatch?.[1] ?? '-1', 10);
	const statusCol = exitCode === 0
		? `${GREEN}✓ done${RESET}`
		: `${RED}✗ exit(${exitCode})${RESET}`;
	return { statusCol, uptimeCol: `${DIM}${container.startedAt}${RESET}` };
}

function serviceDisplay(container: ContainerInfo | undefined): HealthDisplay {
	if (!container) return { statusCol: `${DIM}○ —${RESET}`, uptimeCol: `${DIM}—${RESET}` };

	switch (container.health) {
		case 'healthy':
			return { statusCol: `${GREEN}● healthy${RESET}`, uptimeCol: container.startedAt };
		case 'running':
			return { statusCol: `${YELLOW}● running${RESET}`, uptimeCol: container.startedAt };
		case 'starting':
			return { statusCol: `${YELLOW}◐ starting${RESET}`, uptimeCol: container.startedAt };
		case 'unhealthy':
			return { statusCol: `${RED}● unhealthy${RESET}`, uptimeCol: container.startedAt };
		case 'exited':
			return exitedDisplay(container);
		default:
			return { statusCol: `${DIM}? ${container.health}${RESET}`, uptimeCol: container.startedAt };
	}
}

function knownServiceRows(serviceMap: Map<string, ContainerInfo>): string[] {
	return SERVICES.map((service) => {
		const { statusCol, uptimeCol } = serviceDisplay(serviceMap.get(service));
		return healthColumnRow(`${colorFor(service)}${service}${RESET}`, statusCol, uptimeCol);
	});
}

function extraContainerRows(containers: ContainerInfo[]): string[] {
	return containers
		.filter((container) => !isKnownService(container.service))
		.map((container) => healthColumnRow(
			`${colorFor(container.service)}${container.service || container.name}${RESET}`,
			`${YELLOW}● ${container.health}${RESET}`,
			container.startedAt,
		));
}

function healthSummaryRows(containers: ContainerInfo[]): string[] {
	const total = containers.length;
	const up = containers.filter((container) => UP_HEALTH_STATES.has(container.health)).length;
	const unhealthy = containers.filter((container) => container.health === 'unhealthy').length;
	const exited = containers.filter((container) => container.health === 'exited').length;
	const unhealthyColor = unhealthy > 0 ? RED : DIM;
	const summaryLeft = `${GREEN}● ${up} up${RESET}   ${unhealthyColor}● ${unhealthy} unhealthy${RESET}   ${DIM}✗ ${exited} exited${RESET}`;
	const summaryRight = `${BOLD}${total}${RESET} ${DIM}total${RESET}`;
	const summaryGap = HEALTH_INNER_WIDTH - 2 - stripAnsi(summaryLeft).length - stripAnsi(summaryRight).length;

	return [
		healthColumnRule('├', '┴', '┤'),
		`${HEALTH_BORDER} ${summaryLeft}${' '.repeat(Math.max(1, summaryGap))}${summaryRight} ${HEALTH_BORDER}`,
		healthFullRule('└', '┘'),
		'',
	];
}

function renderHealthMatrix(): string {
	const containers = listContainers();
	const serviceMap = new Map(containers.map((container) => [container.service, container]));

	return [
		'',
		...healthHeaderRows(),
		...knownServiceRows(serviceMap),
		...extraContainerRows(containers),
		...healthSummaryRows(containers),
	].join('\n');
}

// ─── Smart Log Formatting ───────────────────────────────────────────────────

type LogLevel = 'TRACE' | 'DEBUG' | 'INFO' | 'WARN' | 'ERROR' | 'FATAL';

interface ParsedLog {
	level: LogLevel;
	message: string;
	skip?: boolean;
}

const LEVEL_COLORS: Record<LogLevel, string> = {
	TRACE: DIM,
	DEBUG: BLUE,
	INFO: GREEN,
	WARN: YELLOW,
	ERROR: RED,
	FATAL: BRIGHT_RED,
};

function pinoLevel(n: number | string): LogLevel {
	const v = typeof n === 'string' ? Number.parseInt(n, 10) : n;
	if (v >= 60) return 'FATAL';
	if (v >= 50) return 'ERROR';
	if (v >= 40) return 'WARN';
	if (v >= 30) return 'INFO';
	if (v >= 20) return 'DEBUG';
	return 'TRACE';
}

function strLevel(s: string): LogLevel {
	const l = s.toLowerCase();
	if (l === 'fatal' || l === 'crit' || l === 'critical') return 'FATAL';
	if (l === 'error' || l === 'err') return 'ERROR';
	if (l === 'warn' || l === 'warning') return 'WARN';
	if (l === 'info' || l === 'notice' || l === 'log') return 'INFO';
	if (l === 'debug') return 'DEBUG';
	if (l === 'trace') return 'TRACE';
	return 'INFO';
}

function mongoSeverity(s: string): LogLevel {
	switch (s) {
		case 'F': return 'FATAL';
		case 'E': return 'ERROR';
		case 'W': return 'WARN';
		case 'D': case 'D1': case 'D2': case 'D3': case 'D4': case 'D5': return 'DEBUG';
		default: return 'INFO';
	}
}

function isHealthCheck(url: string): boolean {
	return /\/health\/(live|ready|startup)/.test(url);
}

function statusCodeColor(statusCode: number): string {
	if (statusCode >= 500) return RED;
	if (statusCode >= 400) return YELLOW;
	return GREEN;
}

// ── Format Parsers ──────────────────────────────────────────────────────────

function tryPino(raw: string): ParsedLog | null {
	try {
		const j = JSON.parse(raw) as Record<string, unknown>;
		if (typeof j['level'] !== 'number' || j['time'] == null) return null;

		const level = pinoLevel(j['level']);
		const msg = safeString(j['msg'] ?? j['message']);
		const req = asRecord(j['req']);
		const res = asRecord(j['res']);

		if (req && res) {
			const method = safeString(req['method']);
			const url = safeString(req['url']);
			const sc = Number(res['statusCode'] ?? 0);
			let rt = '';
			if (j['responseTime'] != null) rt = `${safeString(j['responseTime'])}ms`;
			if (isHealthCheck(url)) return { level, message: '', skip: true };
			const scColor = statusCodeColor(sc);
			return {
				level,
				message: `${BOLD}${method}${RESET} ${url} ${scColor}${sc}${RESET} ${DIM}${rt}${RESET}`,
			};
		}

		const context = safeString(j['context']);
		const ctx = context ? `${DIM}[${context}]${RESET} ` : '';
		return { level, message: `${ctx}${msg}` };
	} catch {
		return null;
	}
}

function tryGotrue(raw: string): ParsedLog | null {
	try {
		const j = JSON.parse(raw) as Record<string, unknown>;
		if (typeof j['level'] !== 'string' || typeof j['time'] !== 'string') return null;
		if (j['msg'] == null) return null;

		const level = strLevel(j['level']);
		const componentName = safeString(j['component']);
		const component = componentName ? `${DIM}[${componentName}]${RESET} ` : '';
		const msg = safeString(j['msg'])
			.replace(/applying connection limits to db using the "(\w+)" strategy.*/, 'connection limits applied ($1 strategy)');

		return { level, message: `${component}${msg}` };
	} catch {
		return null;
	}
}

function tryMongo(raw: string): ParsedLog | null {
	try {
		const j = JSON.parse(raw) as Record<string, unknown>;
		const t = asRecord(j['t']);
		if (!t?.['$date']) return null;

		const level = mongoSeverity(safeString(j['s'], 'I'));
		const component = safeString(j['c']);
		const msg = safeString(j['msg']);
		const attr = asRecord(j['attr']);

		const isConnChurn = component === 'NETWORK'
			&& /^(Connection (accepted|ended)|client metadata|Received first command)/.test(msg);
		const isAuthNoise = component === 'ACCESS'
			&& /^(Connection not authenticating|Auth metrics report|Successfully authenticated)/.test(msg);
		if (isConnChurn || isAuthNoise) return { level, message: '', skip: true };

		const cmpTag = component ? `${DIM}[${component}]${RESET} ` : '';
		let extra = '';
		if (attr) {
			const remote = safeString(attr['remote']);
			const connectionCount = safeString(attr['connectionCount']);
			if (remote) extra = ` ${DIM}${remote}${RESET}`;
			if (connectionCount) extra += ` ${DIM}conns:${connectionCount}${RESET}`;
		}

		return { level, message: `${cmpTag}${msg}${extra}` };
	} catch {
		return null;
	}
}

// ── Regex parsers for non-JSON formats ──────────────────────────────────────

const VAULT_RE = /^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s+\[(\w+)]\s+(.*)/;
const VAULT_BANNER_RE = /^==>?\s*(.*)/;
const POSTGREST_TS_RE = /^\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2}\s+[+-]\d{4}:\s*(.*)/;
const POSTGREST_FATAL_RE = /^FATAL:\s*(.*)/;
const POSTGRES_RE = /^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+\s+\w+\s+\[\d+]\s+(\w+):\s*(.*)/;
const REALTIME_RE = /^\d{4}-\d{2}-\d{2}T[\d:.]+Z?\s+(\w+)\s+([\w:]+)\s*(.*)/;
const NGINX_RE = /^\d{4}\/\d{2}\/\d{2}\s+\d{2}:\d{2}:\d{2}\s+\[(\w+)]\s+[\d#]+:\s*(.*)/;
const GENERIC_LEVEL_RE = /^(?:nginx:\s*)?\[(\w+)]\s*(.*)/;

function postgresLevel(level: string): LogLevel {
	const pgLevel = level.toUpperCase();
	if (pgLevel === 'ERROR' || pgLevel === 'FATAL' || pgLevel === 'PANIC') return 'ERROR';
	if (pgLevel === 'WARNING') return 'WARN';
	if (pgLevel === 'DEBUG') return 'DEBUG';
	return 'INFO';
}

function tryTextParsers(raw: string): ParsedLog | null {
	let match = VAULT_RE.exec(raw);
	if (match) {
		const [, level = '', message = ''] = match;
		return { level: strLevel(level), message };
	}

	match = VAULT_BANNER_RE.exec(raw);
	if (match) {
		const [, message = ''] = match;
		return { level: 'INFO', message: `${BOLD}${message}${RESET}` };
	}

	match = POSTGREST_FATAL_RE.exec(raw);
	if (match) {
		const [, message = ''] = match;
		return { level: 'ERROR', message };
	}

	match = POSTGREST_TS_RE.exec(raw);
	if (match) {
		const [, msg = ''] = match;
		const lvl: LogLevel = /failed|error|fatal/i.test(msg) ? 'ERROR' : 'INFO';
		return { level: lvl, message: msg };
	}

	match = POSTGRES_RE.exec(raw);
	if (match) {
		const [, level = '', message = ''] = match;
		return { level: postgresLevel(level), message };
	}

	match = REALTIME_RE.exec(raw);
	if (match) {
		const [, level = '', moduleName = '', rawMsg = ''] = match;
		const module = moduleName.endsWith(':') ? moduleName.slice(0, -1) : moduleName;
		const msg = rawMsg.trim();
		return {
			level: strLevel(level),
			message: msg ? `${DIM}[${module}]${RESET} ${msg}` : `${DIM}[${module}]${RESET}`,
		};
	}

	match = NGINX_RE.exec(raw);
	if (match) {
		const [, level = '', message = ''] = match;
		return { level: strLevel(level), message };
	}

	match = GENERIC_LEVEL_RE.exec(raw);
	if (match) {
		const [, level = '', message = ''] = match;
		return { level: strLevel(level), message };
	}

	return null;
}

function parseLogLine(raw: string, stream: 'stdout' | 'stderr'): ParsedLog {
	const clean = raw.replaceAll(ANSI_ESCAPE_RE, '');

	if (/^\d{4}-\d{2}-\d{2}T[\d:.]+Z?\s*$/.test(clean))
		return { level: 'INFO', message: '', skip: true };

	const pino = tryPino(clean);
	if (pino) return pino;
	const gotrue = tryGotrue(clean);
	if (gotrue) return gotrue;
	const mongo = tryMongo(clean);
	if (mongo) return mongo;
	const text = tryTextParsers(clean);
	if (text) return text;
	if (!clean.trim()) return { level: 'INFO', message: '', skip: true };
	return { level: stream === 'stderr' ? 'WARN' : 'INFO', message: clean };
}

// ─── Format a log entry for terminal output ─────────────────────────────────

function formatLogEntry(entry: LogEntry): { formatted: string; level: LogLevel; service: string } | null {
	const parsed = parseLogLine(entry.message, entry.stream);
	if (parsed.skip) return null;

	const color = colorFor(entry.service);
	const ts = `${DIM}${entry.timestamp}${RESET}`;
	const svcLabel = `${color}${pad(entry.service, 20)}${RESET}`;
	const levelColor = LEVEL_COLORS[parsed.level] ?? DIM;
	const levelStr = `${levelColor}${BOLD}${pad(parsed.level, 5)}${RESET}`;

	return {
		formatted: `${ts}  ${svcLabel} ${levelStr}  ${parsed.message}`,
		level: parsed.level,
		service: entry.service,
	};
}

// ─── Filter State (mutable, changed by interactive commands) ────────────────

interface FilterState {
	/** Only show these levels (empty = all) */
	levels: Set<LogLevel>;
	/** Only show these services (empty = all) */
	services: Set<string>;
	/** Pause output (buffer kept flowing, just not printed) */
	paused: boolean;
	/** Grep pattern */
	grep: RegExp | null;
}

function defaultFilter(): FilterState {
	return { levels: new Set(), services: new Set(), paused: false, grep: null };
}

function matchesFilter(f: FilterState, level: LogLevel, service: string, formatted: string): boolean {
	if (f.paused) return false;
	if (f.levels.size > 0 && !f.levels.has(level)) return false;
	if (f.services.size > 0 && !f.services.has(service)) return false;
	if (f.grep && !f.grep.test(stripAnsi(formatted))) return false;
	return true;
}

// ─── Interactive REPL ───────────────────────────────────────────────────────

const HELP_TEXT = `
${BOLD}${CYAN}─── Observatory Commands ───────────────────────────────────────${RESET}

  ${BOLD}${GREEN}status${RESET}  ${DIM}|${RESET} ${GREEN}health${RESET} ${DIM}|${RESET} ${GREEN}s${RESET}      Show the health matrix
  ${BOLD}${GREEN}errors${RESET}  ${DIM}|${RESET} ${GREEN}e${RESET}                Filter: show only ERROR + FATAL
  ${BOLD}${GREEN}warnings${RESET}  ${DIM}|${RESET} ${GREEN}w${RESET}              Filter: show only WARN + ERROR + FATAL
  ${BOLD}${GREEN}info${RESET}  ${DIM}|${RESET} ${GREEN}i${RESET}                  Filter: show INFO and above
  ${BOLD}${GREEN}all${RESET}  ${DIM}|${RESET} ${GREEN}a${RESET}                   Reset: show all log levels
  ${BOLD}${GREEN}service${RESET} ${WHITE}<name,...>${RESET}       Filter: show only specific service(s)
  ${BOLD}${GREEN}grep${RESET} ${WHITE}<pattern>${RESET}          Filter: show lines matching regex
  ${BOLD}${GREEN}grep${RESET}                       Clear grep filter
  ${BOLD}${GREEN}pause${RESET}  ${DIM}|${RESET} ${GREEN}p${RESET}                Pause log output
  ${BOLD}${GREEN}resume${RESET}  ${DIM}|${RESET} ${GREEN}r${RESET}               Resume log output
  ${BOLD}${GREEN}clear${RESET}  ${DIM}|${RESET} ${GREEN}c${RESET}                Clear the terminal
  ${BOLD}${GREEN}filter${RESET}  ${DIM}|${RESET} ${GREEN}f${RESET}               Show current filter state
  ${BOLD}${GREEN}services${RESET}                   List available services
  ${BOLD}${GREEN}help${RESET}  ${DIM}|${RESET} ${GREEN}h${RESET}  ${DIM}|${RESET} ${GREEN}?${RESET}            Show this help
  ${BOLD}${GREEN}quit${RESET}  ${DIM}|${RESET} ${GREEN}q${RESET}  ${DIM}|${RESET} ${GREEN}exit${RESET}         Stop the observatory

${DIM}  Combine services: ${RESET}${BOLD}service kong,realtime${RESET}
${CYAN}────────────────────────────────────────────────────────────────${RESET}
`;

const PROMPT = `${BOLD}${CYAN}observatory${RESET}${DIM}>${RESET} `;

interface InteractiveCommandContext {
	filterState: FilterState;
	shutdownFn: () => void;
}

interface InteractiveInput {
	command: string;
	arg: string;
}

type InteractiveCommandHandler = (arg: string, context: InteractiveCommandContext) => boolean;

function parseInteractiveInput(input: string): InteractiveInput | null {
	const raw = input.trim();
	if (!raw) return null;
	const [command = '', ...rest] = raw.split(/\s+/);
	return { command: command.toLowerCase(), arg: rest.join(' ') };
}

function setLevelFilter(filterState: FilterState, levels: LogLevel[], label: string): boolean {
	filterState.levels = new Set<LogLevel>(levels);
	filterState.paused = false;
	process.stdout.write(`${GREEN}Filter: ${BOLD}${label}${RESET}\n`);
	return true;
}

function showHealthCommand(): boolean {
	process.stdout.write(renderHealthMatrix() + '\n');
	return true;
}

function showErrorsCommand(_arg: string, context: InteractiveCommandContext): boolean {
	return setLevelFilter(context.filterState, ['ERROR', 'FATAL'], 'ERROR + FATAL');
}

function showWarningsCommand(_arg: string, context: InteractiveCommandContext): boolean {
	return setLevelFilter(context.filterState, ['WARN', 'ERROR', 'FATAL'], 'WARN + ERROR + FATAL');
}

function showInfoCommand(_arg: string, context: InteractiveCommandContext): boolean {
	return setLevelFilter(context.filterState, ['INFO', 'WARN', 'ERROR', 'FATAL'], 'INFO and above');
}

function resetFiltersCommand(_arg: string, context: InteractiveCommandContext): boolean {
	const { filterState } = context;
	filterState.levels.clear();
	filterState.services.clear();
	filterState.grep = null;
	filterState.paused = false;
	process.stdout.write(`${GREEN}Filter reset: ${BOLD}showing all logs${RESET}\n`);
	return true;
}

function serviceFilterCommand(arg: string, context: InteractiveCommandContext): boolean {
	const { filterState } = context;
	if (arg) {
		const services = arg.split(',').map((service) => service.trim()).filter(Boolean);
		filterState.services = new Set(services);
		process.stdout.write(`${GREEN}Filter: services = ${BOLD}${services.join(', ')}${RESET}\n`);
	} else {
		filterState.services.clear();
		process.stdout.write(`${GREEN}Service filter cleared: ${BOLD}showing all services${RESET}\n`);
	}
	return true;
}

function grepCommand(arg: string, context: InteractiveCommandContext): boolean {
	const { filterState } = context;
	if (arg) {
		try {
			filterState.grep = new RegExp(arg, 'i');
			process.stdout.write(`${GREEN}Grep: ${BOLD}/${arg}/i${RESET}\n`);
		} catch {
			process.stdout.write(`${RED}Invalid regex: ${arg}${RESET}\n`);
		}
	} else {
		filterState.grep = null;
		process.stdout.write(`${GREEN}Grep filter cleared${RESET}\n`);
	}
	return true;
}

function pauseCommand(_arg: string, context: InteractiveCommandContext): boolean {
	context.filterState.paused = true;
	process.stdout.write(`${YELLOW}${BOLD}⏸  Log output paused${RESET} ${DIM}(type 'resume' to continue)${RESET}\n`);
	return true;
}

function resumeCommand(_arg: string, context: InteractiveCommandContext): boolean {
	context.filterState.paused = false;
	process.stdout.write(`${GREEN}${BOLD}▶  Log output resumed${RESET}\n`);
	return true;
}

function clearCommand(): boolean {
	process.stdout.write('\x1Bc');
	return true;
}

function formattedSet<T extends string>(values: Set<T>): string {
	if (values.size === 0) return `${DIM}all${RESET}`;
	return Array.from(values).join(', ');
}

function formattedGrep(grep: RegExp | null): string {
	if (grep) return `/${grep.source}/${grep.flags}`;
	return `${DIM}none${RESET}`;
}

function formattedPaused(paused: boolean): string {
	if (paused) return `${YELLOW}yes${RESET}`;
	return `${GREEN}no${RESET}`;
}

function filterCommand(_arg: string, context: InteractiveCommandContext): boolean {
	const { filterState } = context;
	const levels = formattedSet(filterState.levels);
	const services = formattedSet(filterState.services);
	const grep = formattedGrep(filterState.grep);
	const paused = formattedPaused(filterState.paused);
	process.stdout.write(
		`\n${BOLD}Current filter:${RESET}\n` +
		`  Levels:   ${levels}\n` +
		`  Services: ${services}\n` +
		`  Grep:     ${grep}\n` +
		`  Paused:   ${paused}\n\n`,
	);
	return true;
}

function servicesCommand(): boolean {
	const services = SERVICES
		.map((service) => `  ${colorFor(service)}${service}${RESET}`)
		.join('\n');
	process.stdout.write(`\n${BOLD}Available services:${RESET}\n${services}\n\n`);
	return true;
}

function helpCommand(): boolean {
	process.stdout.write(HELP_TEXT);
	return true;
}

function quitCommand(_arg: string, context: InteractiveCommandContext): boolean {
	context.shutdownFn();
	return false;
}

const COMMAND_HANDLERS = new Map<string, InteractiveCommandHandler>([
	['status', showHealthCommand],
	['health', showHealthCommand],
	['s', showHealthCommand],
	['errors', showErrorsCommand],
	['e', showErrorsCommand],
	['warnings', showWarningsCommand],
	['w', showWarningsCommand],
	['info', showInfoCommand],
	['i', showInfoCommand],
	['all', resetFiltersCommand],
	['a', resetFiltersCommand],
	['service', serviceFilterCommand],
	['svc', serviceFilterCommand],
	['grep', grepCommand],
	['g', grepCommand],
	['pause', pauseCommand],
	['p', pauseCommand],
	['resume', resumeCommand],
	['r', resumeCommand],
	['clear', clearCommand],
	['c', clearCommand],
	['filter', filterCommand],
	['f', filterCommand],
	['services', servicesCommand],
	['help', helpCommand],
	['h', helpCommand],
	['?', helpCommand],
	['quit', quitCommand],
	['q', quitCommand],
	['exit', quitCommand],
]);

function handleInteractiveInput(input: string, context: InteractiveCommandContext): boolean {
	const parsed = parseInteractiveInput(input);
	if (!parsed) return true;

	const handler = COMMAND_HANDLERS.get(parsed.command);
	if (handler) return handler(parsed.arg, context);

	process.stdout.write(`${DIM}Unknown command: ${parsed.command}. Type 'help' for available commands.${RESET}\n`);
	return true;
}

function startInteractivePrompt(
	filterState: FilterState,
	shutdownFn: () => void,
): RLInterface {
	const rl = createInterface({
		input: process.stdin,
		output: process.stdout,
		prompt: PROMPT,
		terminal: true,
	});

	// Show prompt after banner + initial health matrix
	rl.prompt();

	rl.on('line', (input) => {
		if (handleInteractiveInput(input, { filterState, shutdownFn })) rl.prompt();
	});

	rl.on('close', () => {
		shutdownFn();
	});

	return rl;
}

// ─── PID File (headless mode) ───────────────────────────────────────────────

function writePidFile(): void {
	fs.writeFileSync(PID_FILE, String(process.pid), 'utf-8');
}

function removePidFile(): void {
	try { fs.unlinkSync(PID_FILE); } catch { /* ignore */ }
}

// ─── Main ───────────────────────────────────────────────────────────────────

function main(): void {
	SERVICES = getActiveServices();
	const mode = resolveMode();

	const destroy$ = new Subject<void>();
	const subscriptions: Subscription[] = [];
	const activeStreams = new Map<string, Subscription>();
	const filterState = defaultFilter();
	let rl: RLInterface | null = null;
	let shuttingDown = false;

	// ── PID file for headless ──
	if (mode === 'headless') {
		writePidFile();
		process.on('exit', removePidFile);
	}

	// ── Graceful shutdown ──
	const shutdown = () => {
		if (shuttingDown) return;
		shuttingDown = true;
		if (rl) {
			rl.removeAllListeners();
			rl.close();
		}
		process.stdout.write(`\n${YELLOW}${BOLD}Observatory shutting down…${RESET}\n`);
		destroy$.next();
		destroy$.complete();
		for (const sub of subscriptions) sub.unsubscribe();
		activeStreams.forEach((sub) => sub.unsubscribe());
		removePidFile();
		process.exit(0);
	};
	process.on('SIGINT', shutdown);
	process.on('SIGTERM', shutdown);

	// ── Banner ──
	if (mode !== 'headless') {
		process.stdout.write(`
${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║   ${WHITE}mini-BaaS Observatory${CYAN}                                   ║
║   ${DIM}Real-time log stream${RESET}${BOLD}${CYAN}                                     ║
║   ${DIM}Type ${WHITE}help${DIM} for commands    ${RESET}${BOLD}${CYAN}                               ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝${RESET}

`);
	}

	// ── Show initial health matrix (once, on-demand only after this) ──
	if (mode !== 'headless') {
		process.stdout.write(renderHealthMatrix() + '\n');
	}

	// ── Log output function (respects filter) ──
	function outputLog(entry: LogEntry): void {
		const result = formatLogEntry(entry);
		if (!result) return;
		if (!matchesFilter(filterState, result.level, result.service, result.formatted)) return;
		process.stdout.write(result.formatted + '\n');
	}

	// ── Attach / Detach containers ──
	function attachContainer(containerId: string, service: string): void {
		if (activeStreams.has(containerId)) return;

		const log$ = containerLogs$(containerId, service).pipe(
			catchError(() => EMPTY),
			finalize(() => activeStreams.delete(containerId)),
			takeUntil(destroy$),
		);

		const sub = log$.subscribe({
			next: (entry) => outputLog(entry),
		});

		activeStreams.set(containerId, sub);
	}

	function detachContainer(containerId: string): void {
		const sub = activeStreams.get(containerId);
		if (sub) {
			sub.unsubscribe();
			activeStreams.delete(containerId);
		}
	}

	// ── Attach to existing containers ──
	const existing = listContainers().filter((c) => c.health !== 'exited' && c.health !== 'created');

	if (existing.length === 0) {
		process.stdout.write(
			`${YELLOW}${BOLD}No running containers found.${RESET}\n` +
			`${DIM}Listening for Docker events — containers will be attached when started…${RESET}\n\n`,
		);
	} else {
		process.stdout.write(
			`${GREEN}${BOLD}Attaching to ${existing.length} running containers…${RESET}\n\n`,
		);
		for (const c of existing) {
			attachContainer(c.id, c.service);
		}
	}

	// ── Docker Events (dynamic attach/detach) ──
	const events$ = dockerEvents$().pipe(
		catchError(() => EMPTY),
		takeUntil(destroy$),
	);

	subscriptions.push(events$.subscribe({
		next: (evt) => {
			if (evt.type === 'start') {
				process.stdout.write(
					`\n${GREEN}${BOLD}▶ Container started: ${evt.service}${RESET}\n`,
				);
				setTimeout(() => attachContainer(evt.containerId, evt.service), 500);
			} else if (evt.type === 'stop' || evt.type === 'die') {
				process.stdout.write(
					`\n${RED}${BOLD}■ Container stopped: ${evt.service}${RESET}\n`,
				);
				detachContainer(evt.containerId);
			}
		},
	}));

	// ── Interactive prompt (only in interactive mode) ──
	if (mode === 'interactive') {
		rl = startInteractivePrompt(filterState, shutdown);
	}
}

main();
