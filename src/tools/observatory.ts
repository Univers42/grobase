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
 *   pnpm exec ts-node -r tsconfig-paths/register tools/observatory.ts
 *   pnpm exec ts-node -r tsconfig-paths/register tools/observatory.ts --headless
 *   pnpm exec ts-node -r tsconfig-paths/register tools/observatory.ts --logs
 *
 * Requires: Docker socket access (/var/run/docker.sock)
 */

import { execSync, spawn } from 'child_process';
import { createInterface, Interface as RLInterface } from 'readline';
import * as fs from 'fs';
import * as path from 'path';
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

// ─── Modes ──────────────────────────────────────────────────────────────────

type Mode = 'interactive' | 'headless' | 'logs';

function resolveMode(): Mode {
	const args = process.argv.slice(2);
	if (args.includes('--headless')) return 'headless';
	if (args.includes('--logs') || args.includes('--logs-only')) return 'logs';
	return 'interactive';
}

// ─── Service Discovery ─────────────────────────────────────────────────────

function getActiveServices(): string[] {
	try {
		return execSync('docker compose config --services', {
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
	return PALETTE[Math.abs(i) % PALETTE.length]!;
}

function hashCode(s: string): number {
	let h = 0;
	for (let i = 0; i < s.length; i++) {
		h = (Math.imul(31, h) + s.charCodeAt(i)) | 0;
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
	// eslint-disable-next-line no-control-regex
	return s.replace(/\x1b\[[0-9;]*m/g, '');
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
		const raw = execSync(
			`docker ps -a --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" ` +
			`--format '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.service"}}|{{.Status}}|{{.State}}'`,
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

			const startedAt = status.replace(/\s*\(.*\)/, '');
			return {
				id: id.trim(), name: name.trim(), service: service.trim(),
				status: status.trim(), health, startedAt: startedAt.trim(),
			};
		});
	} catch {
		return [];
	}
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
		const proc = spawn('docker', ['logs', '--follow', '--tail', '50', containerId], {
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
			'docker',
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

function renderHealthMatrix(): string {
	const containers = listContainers();
	const serviceMap = new Map<string, ContainerInfo>();
	for (const c of containers) serviceMap.set(c.service, c);

	const C1 = 20;
	const C2 = 14;
	const C3 = 26;
	const INNER = C1 + C2 + C3 + 8;

	const B = `${CYAN}│${RESET}`;

	const colRow = (a: string, b: string, c: string) =>
		`${B} ${vpad(a, C1)} ${B} ${vpad(b, C2)} ${B} ${vpad(c, C3)} ${B}`;

	const hrFull = (l: string, r: string) =>
		`${CYAN}${l}${'─'.repeat(INNER)}${r}${RESET}`;

	const hrCols = (l: string, x: string, r: string) =>
		`${CYAN}${l}${'─'.repeat(C1 + 2)}${x}${'─'.repeat(C2 + 2)}${x}${'─'.repeat(C3 + 2)}${r}${RESET}`;

	const lines: string[] = [''];

	lines.push(hrFull('┌', '┐'));
	const titleText = `${BOLD}${WHITE}mini-BaaS Health Matrix${RESET}`;
	const tsText = `${DIM}${timestamp()}${RESET}`;
	const titleGap = INNER - 2 - 22 - 8;
	lines.push(`${B} ${titleText}${' '.repeat(Math.max(1, titleGap))}${tsText} ${B}`);

	lines.push(hrCols('├', '┬', '┤'));
	lines.push(colRow(
		`${BOLD}Service${RESET}`,
		`${BOLD}Status${RESET}`,
		`${BOLD}Uptime${RESET}`,
	));
	lines.push(hrCols('├', '┼', '┤'));

	for (const svc of SERVICES) {
		const c = serviceMap.get(svc);
		const color = colorFor(svc);
		let statusCol: string;
		let uptimeCol: string;

		if (!c) {
			statusCol = `${DIM}○ —${RESET}`;
			uptimeCol = `${DIM}—${RESET}`;
		} else if (c.health === 'healthy') {
			statusCol = `${GREEN}● healthy${RESET}`;
			uptimeCol = c.startedAt;
		} else if (c.health === 'running') {
			statusCol = `${YELLOW}● running${RESET}`;
			uptimeCol = c.startedAt;
		} else if (c.health === 'starting') {
			statusCol = `${YELLOW}◐ starting${RESET}`;
			uptimeCol = c.startedAt;
		} else if (c.health === 'unhealthy') {
			statusCol = `${RED}● unhealthy${RESET}`;
			uptimeCol = c.startedAt;
		} else if (c.health === 'exited') {
			const exitMatch = c.status.match(/Exited\s*\((\d+)\)/);
			const exitCode = exitMatch ? parseInt(exitMatch[1]!, 10) : -1;
			statusCol = exitCode === 0
				? `${GREEN}✓ done${RESET}`
				: `${RED}✗ exit(${exitCode})${RESET}`;
			uptimeCol = `${DIM}${c.startedAt}${RESET}`;
		} else {
			statusCol = `${DIM}? ${c.health}${RESET}`;
			uptimeCol = c.startedAt;
		}

		lines.push(colRow(`${color}${svc}${RESET}`, statusCol, uptimeCol));
	}

	for (const c of containers) {
		if (isKnownService(c.service)) continue;
		lines.push(colRow(
			`${colorFor(c.service)}${c.service || c.name}${RESET}`,
			`${YELLOW}● ${c.health}${RESET}`,
			c.startedAt,
		));
	}

	const total = containers.length;
	const up = containers.filter((c) => ['healthy', 'running', 'starting'].includes(c.health)).length;
	const unhealthy = containers.filter((c) => c.health === 'unhealthy').length;
	const exited = containers.filter((c) => c.health === 'exited').length;

	lines.push(hrCols('├', '┴', '┤'));
	const summaryLeft = `${GREEN}● ${up} up${RESET}   ${unhealthy > 0 ? RED : DIM}● ${unhealthy} unhealthy${RESET}   ${DIM}✗ ${exited} exited${RESET}`;
	const summaryRight = `${BOLD}${total}${RESET} ${DIM}total${RESET}`;
	const sGap = INNER - 2 - stripAnsi(summaryLeft).length - stripAnsi(summaryRight).length;
	lines.push(`${B} ${summaryLeft}${' '.repeat(Math.max(1, sGap))}${summaryRight} ${B}`);
	lines.push(hrFull('└', '┘'));
	lines.push('');

	return lines.join('\n');
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
	const v = typeof n === 'string' ? parseInt(n, 10) : n;
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

// ── Format Parsers ──────────────────────────────────────────────────────────

function tryPino(raw: string): ParsedLog | null {
	try {
		const j = JSON.parse(raw) as Record<string, unknown>;
		if (typeof j['level'] !== 'number' || j['time'] == null) return null;

		const level = pinoLevel(j['level'] as number);
		const msg = String(j['msg'] ?? j['message'] ?? '');
		const req = j['req'] as Record<string, unknown> | undefined;
		const res = j['res'] as Record<string, unknown> | undefined;

		if (req && res) {
			const method = String(req['method'] ?? '');
			const url = String(req['url'] ?? '');
			const sc = Number(res['statusCode'] ?? 0);
			const rt = j['responseTime'] != null ? `${j['responseTime']}ms` : '';
			if (isHealthCheck(url)) return { level, message: '', skip: true };
			const scColor = sc >= 500 ? RED : sc >= 400 ? YELLOW : GREEN;
			return {
				level,
				message: `${BOLD}${method}${RESET} ${url} ${scColor}${sc}${RESET} ${DIM}${rt}${RESET}`,
			};
		}

		const ctx = j['context'] ? `${DIM}[${j['context']}]${RESET} ` : '';
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
		if (typeof j['level'] === 'number') return null;

		const level = strLevel(j['level'] as string);
		const component = j['component'] ? `${DIM}[${j['component']}]${RESET} ` : '';
		const msg = String(j['msg'] ?? '')
			.replace(/applying connection limits to db using the "(\w+)" strategy.*/, 'connection limits applied ($1 strategy)');

		return { level, message: `${component}${msg}` };
	} catch {
		return null;
	}
}

function tryMongo(raw: string): ParsedLog | null {
	try {
		const j = JSON.parse(raw) as Record<string, unknown>;
		const t = j['t'] as Record<string, unknown> | undefined;
		if (!t || !t['$date']) return null;

		const level = mongoSeverity(String(j['s'] ?? 'I'));
		const component = String(j['c'] ?? '');
		const msg = String(j['msg'] ?? '');
		const attr = j['attr'] as Record<string, unknown> | undefined;

		const isConnChurn = component === 'NETWORK'
			&& /^(Connection (accepted|ended)|client metadata|Received first command)/.test(msg);
		const isAuthNoise = component === 'ACCESS'
			&& /^(Connection not authenticating|Auth metrics report|Successfully authenticated)/.test(msg);
		if (isConnChurn || isAuthNoise) return { level, message: '', skip: true };

		const cmpTag = component ? `${DIM}[${component}]${RESET} ` : '';
		let extra = '';
		if (attr) {
			if (attr['remote']) extra = ` ${DIM}${attr['remote']}${RESET}`;
			if (attr['connectionCount'] != null) extra += ` ${DIM}conns:${attr['connectionCount']}${RESET}`;
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
const REALTIME_RE = /^\d{4}-\d{2}-\d{2}T[\d:.]+Z?\s+(\w+)\s+([\w_:]+)\s*(.*)/;
const NGINX_RE = /^\d{4}\/\d{2}\/\d{2}\s+\d{2}:\d{2}:\d{2}\s+\[(\w+)]\s+[\d#]+:\s*(.*)/;
const GENERIC_LEVEL_RE = /^(?:nginx:\s*)?\[(\w+)]\s*(.*)/;

function tryTextParsers(raw: string): ParsedLog | null {
	let m: RegExpMatchArray | null;

	if ((m = raw.match(VAULT_RE)))
		return { level: strLevel(m[1]!), message: m[2]! };
	if ((m = raw.match(VAULT_BANNER_RE)))
		return { level: 'INFO', message: `${BOLD}${m[1]}${RESET}` };
	if ((m = raw.match(POSTGREST_FATAL_RE)))
		return { level: 'ERROR', message: m[1]! };
	if ((m = raw.match(POSTGREST_TS_RE))) {
		const msg = m[1]!;
		const lvl: LogLevel = /failed|error|fatal/i.test(msg) ? 'ERROR' : 'INFO';
		return { level: lvl, message: msg };
	}
	if ((m = raw.match(POSTGRES_RE))) {
		const pgLevel = m[1]!.toUpperCase();
		let lvl: LogLevel = 'INFO';
		if (pgLevel === 'ERROR' || pgLevel === 'FATAL' || pgLevel === 'PANIC') lvl = 'ERROR';
		else if (pgLevel === 'WARNING') lvl = 'WARN';
		else if (pgLevel === 'DEBUG') lvl = 'DEBUG';
		return { level: lvl, message: m[2]! };
	}
	if ((m = raw.match(REALTIME_RE))) {
		const module = m[2]!.replace(/:$/, '');
		const msg = m[3]!.trim();
		return {
			level: strLevel(m[1]!),
			message: msg ? `${DIM}[${module}]${RESET} ${msg}` : `${DIM}[${module}]${RESET}`,
		};
	}
	if ((m = raw.match(NGINX_RE)))
		return { level: strLevel(m[1]!), message: m[2]! };
	if ((m = raw.match(GENERIC_LEVEL_RE)))
		return { level: strLevel(m[1]!), message: m[2]! };
	return null;
}

function parseLogLine(raw: string, stream: 'stdout' | 'stderr'): ParsedLog {
	// eslint-disable-next-line no-control-regex
	const clean = raw.replace(/\x1b\[[0-9;]*m/g, '');

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
		const raw = input.trim();
		if (!raw) { rl.prompt(); return; }

		const [cmd = '', ...rest] = raw.split(/\s+/);
		const arg = rest.join(' ');

		switch (cmd.toLowerCase()) {
			// ── Health ──
			case 'status':
			case 'health':
			case 's':
				process.stdout.write(renderHealthMatrix() + '\n');
				break;

			// ── Level filters ──
			case 'errors':
			case 'e':
				filterState.levels = new Set<LogLevel>(['ERROR', 'FATAL']);
				filterState.paused = false;
				process.stdout.write(`${GREEN}Filter: ${BOLD}ERROR + FATAL${RESET}\n`);
				break;

			case 'warnings':
			case 'w':
				filterState.levels = new Set<LogLevel>(['WARN', 'ERROR', 'FATAL']);
				filterState.paused = false;
				process.stdout.write(`${GREEN}Filter: ${BOLD}WARN + ERROR + FATAL${RESET}\n`);
				break;

			case 'info':
			case 'i':
				filterState.levels = new Set<LogLevel>(['INFO', 'WARN', 'ERROR', 'FATAL']);
				filterState.paused = false;
				process.stdout.write(`${GREEN}Filter: ${BOLD}INFO and above${RESET}\n`);
				break;

			case 'all':
			case 'a':
				filterState.levels.clear();
				filterState.services.clear();
				filterState.grep = null;
				filterState.paused = false;
				process.stdout.write(`${GREEN}Filter reset: ${BOLD}showing all logs${RESET}\n`);
				break;

			// ── Service filter ──
			case 'service':
			case 'svc':
				if (!arg) {
					filterState.services.clear();
					process.stdout.write(`${GREEN}Service filter cleared: ${BOLD}showing all services${RESET}\n`);
				} else {
					const svcs = arg.split(',').map((s) => s.trim()).filter(Boolean);
					filterState.services = new Set(svcs);
					process.stdout.write(`${GREEN}Filter: services = ${BOLD}${svcs.join(', ')}${RESET}\n`);
				}
				break;

			// ── Grep ──
			case 'grep':
			case 'g':
				if (!arg) {
					filterState.grep = null;
					process.stdout.write(`${GREEN}Grep filter cleared${RESET}\n`);
				} else {
					try {
						filterState.grep = new RegExp(arg, 'i');
						process.stdout.write(`${GREEN}Grep: ${BOLD}/${arg}/i${RESET}\n`);
					} catch {
						process.stdout.write(`${RED}Invalid regex: ${arg}${RESET}\n`);
					}
				}
				break;

			// ── Pause / Resume ──
			case 'pause':
			case 'p':
				filterState.paused = true;
				process.stdout.write(`${YELLOW}${BOLD}⏸  Log output paused${RESET} ${DIM}(type 'resume' to continue)${RESET}\n`);
				break;

			case 'resume':
			case 'r':
				filterState.paused = false;
				process.stdout.write(`${GREEN}${BOLD}▶  Log output resumed${RESET}\n`);
				break;

			// ── Clear ──
			case 'clear':
			case 'c':
				process.stdout.write('\x1Bc');
				break;

			// ── Show filter ──
			case 'filter':
			case 'f':
				process.stdout.write(
					`\n${BOLD}Current filter:${RESET}\n` +
					`  Levels:   ${filterState.levels.size === 0 ? `${DIM}all${RESET}` : Array.from(filterState.levels).join(', ')}\n` +
					`  Services: ${filterState.services.size === 0 ? `${DIM}all${RESET}` : Array.from(filterState.services).join(', ')}\n` +
					`  Grep:     ${filterState.grep ? `/${filterState.grep.source}/${filterState.grep.flags}` : `${DIM}none${RESET}`}\n` +
					`  Paused:   ${filterState.paused ? `${YELLOW}yes${RESET}` : `${GREEN}no${RESET}`}\n\n`,
				);
				break;

			// ── Services list ──
			case 'services':
				process.stdout.write(`\n${BOLD}Available services:${RESET}\n`);
				for (const svc of SERVICES) {
					process.stdout.write(`  ${colorFor(svc)}${svc}${RESET}\n`);
				}
				process.stdout.write('\n');
				break;

			// ── Help ──
			case 'help':
			case 'h':
			case '?':
				process.stdout.write(HELP_TEXT);
				break;

			// ── Quit ──
			case 'quit':
			case 'q':
			case 'exit':
				shutdownFn();
				return;

			default:
				process.stdout.write(`${DIM}Unknown command: ${cmd}. Type 'help' for available commands.${RESET}\n`);
		}

		rl.prompt();
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
