/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   automations.service.ts                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/10 12:00:00 by dlesieur          #+#    #+#             */
/*                                                +#+#+#+#+#+   +#+           */
/* ************************************************************************** */

/**
 * Server-backed database automations: rules persisted per (tenant, mount)
 * in the control Postgres (same DATABASE_URL the outbox uses), evaluated in
 * the write path AFTER a successful mutation — so they fire for EVERY
 * client, not only the session that defined them.
 *
 * Execution posture (mirrors realtime-publisher): fire-and-forget, the
 * write response is never delayed or failed by an automation. Loop safety:
 * follow-up `set_property` writes carry an automation depth and writes at
 * depth ≥ 1 never re-trigger (max chain length 1). Webhooks are HTTPS-only
 * with a private-address guard (SSRF), 5s timeout, no retries.
 */

import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { Pool } from 'pg';
import { AutomationRuleDto } from './dto/automations.dto';

/** A write the runner inspects (one per mutated resource). */
export interface AutomationWriteEvent {
  dbId: string;
  tenantId: string;
  userId: string;
  table: string;
  op: 'insert' | 'update' | 'delete' | 'upsert';
  /** Best-effort row view: RETURNING row, else the write's data/filter. */
  row: Record<string, unknown>;
  /** Best-effort primary key of the touched row. */
  pk?: unknown;
}

/** Injected by QueryService — avoids a DI cycle for follow-up writes. */
export type AutomationWriteExecutor = (
  table: string,
  data: Record<string, unknown>,
  filter: Record<string, unknown>,
) => Promise<unknown>;

const TRIGGER_OPS: Record<string, readonly string[]> = {
  row_added: ['insert', 'upsert'],
  row_updated: ['update', 'upsert'],
  row_deleted: ['delete'],
};

const RULES_CACHE_TTL_MS = 30_000;
const WEBHOOK_TIMEOUT_MS = 5_000;

/**
 * @brief Classify an already-parsed IP literal as non-public (SSRF block-list).
 *
 * Unmaps an IPv4-mapped-IPv6 literal (`::ffff:169.254.169.254`) to its dotted
 * form first — the documented bypass for hostname denylists — then applies the
 * IPv4 / IPv6 private-range rules: loopback, RFC1918/ULA private, link-local
 * (incl. the 169.254.169.254 cloud-metadata range) and CGNAT. Anything not
 * parseable as an IP fails closed (treated as private).
 *
 * @see https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html
 *
 * Exported for unit tests.
 */
export function isPrivateAddress(ip: string): boolean {
  let addr = ip;
  // Unmap a *dotted* IPv4-mapped IPv6 literal (::ffff:169.254.169.254) so the
  // IPv4 rules below catch it. The WHATWG URL parser may instead hand us the
  // *hex* form (::ffff:a9fe:a9fe) — that is caught wholesale in the IPv6 branch
  // below (any address that is not global-unicast is refused).
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i.exec(addr);
  if (mapped) addr = mapped[1];
  const fam = isIP(addr);
  if (fam === 4) {
    const o = addr.split('.').map(Number);
    return (
      o[0] === 0 || o[0] === 10 || o[0] === 127 ||
      (o[0] === 169 && o[1] === 254) ||             // link-local + cloud metadata
      (o[0] === 172 && o[1] >= 16 && o[1] <= 31) || // 172.16.0.0/12
      (o[0] === 192 && o[1] === 168) ||             // 192.168.0.0/16
      (o[0] === 100 && o[1] >= 64 && o[1] <= 127)   // CGNAT 100.64.0.0/10
    );
  }
  if (fam === 6) {
    // Global-unicast IPv6 (the only public range, 2000::/3) never starts with
    // `::`, so refusing every `::*` form blocks loopback (::1), unspecified (::)
    // and BOTH encodings of IPv4-mapped/-compatible addresses (::ffff:a9fe:a9fe
    // and ::ffff:169.254.169.254) — closing the IPv4-mapped-IPv6 bypass. ULA
    // (fc/fd), link-local (fe80) and multicast (ff) are likewise non-public.
    const lower = addr.toLowerCase();
    return (
      lower.startsWith('::') ||
      lower.startsWith('fe80:') ||
      lower.startsWith('fc') || lower.startsWith('fd') ||
      lower.startsWith('ff')
    );
  }
  return true; // not an IP literal → fail closed
}

@Injectable()
export class AutomationsService {
  private readonly logger = new Logger(AutomationsService.name);
  private pool?: Pool;
  private tableReady = false;
  private readonly cache = new Map<string, { rules: AutomationRuleDto[]; expiresAt: number }>();

  constructor(private readonly config: ConfigService) {}

  /** All rules stored for (tenant, mount). TTL-cached for the write path. */
  async listRules(tenantId: string, dbId: string): Promise<AutomationRuleDto[]> {
    const key = `${tenantId}:${dbId}`;
    const cached = this.cache.get(key);
    if (cached && cached.expiresAt > Date.now()) return cached.rules;
    const pool = await this.getPool();
    const result = await pool.query<{ rules: AutomationRuleDto[] }>(
      'SELECT rules FROM automation_rules WHERE tenant_id = $1 AND db_id = $2',
      [tenantId, dbId],
    );
    const rules = result.rows[0]?.rules ?? [];
    this.cache.set(key, { rules, expiresAt: Date.now() + RULES_CACHE_TTL_MS });
    return rules;
  }

  /** Replace-all rule set for (tenant, mount) — PUT semantics. */
  async putRules(tenantId: string, dbId: string, rules: AutomationRuleDto[]): Promise<AutomationRuleDto[]> {
    const pool = await this.getPool();
    await pool.query(
      `INSERT INTO automation_rules (tenant_id, db_id, rules, updated_at)
       VALUES ($1, $2, $3::jsonb, now())
       ON CONFLICT (tenant_id, db_id) DO UPDATE SET rules = $3::jsonb, updated_at = now()`,
      [tenantId, dbId, JSON.stringify(rules)],
    );
    this.cache.set(`${tenantId}:${dbId}`, { rules, expiresAt: Date.now() + RULES_CACHE_TTL_MS });
    return rules;
  }

  /**
   * Fire-and-forget evaluation for one successful write. `notify` events go
   * through `publishNotify` (injected), `set_property` re-enters the write
   * path through `execute` (the caller marks that write with automationDepth
   * so it can never re-trigger).
   */
  async runForWrite(
    event: AutomationWriteEvent,
    execute: AutomationWriteExecutor,
    publishNotify: (rule: AutomationRuleDto, message: string, pk: unknown) => Promise<void>,
  ): Promise<void> {
    let rules: AutomationRuleDto[];
    try {
      rules = await this.listRules(event.tenantId, event.dbId);
    } catch (error) {
      this.logger.debug(`automation rules unavailable: ${(error as Error).message}`);
      return;
    }
    for (const rule of rules) {
      if (!rule.enabled || rule.table !== event.table) continue;
      if (!(TRIGGER_OPS[rule.trigger] ?? []).includes(event.op)) continue;
      if (rule.condition && !evaluateCondition(event.row, rule.condition)) continue;
      for (const action of rule.actions) {
        await this.runAction(rule, action, event, execute, publishNotify).catch((error: Error) =>
          this.logger.warn(`automation "${rule.name}" action ${action.type} failed: ${error.message}`));
      }
    }
  }

  private async runAction(
    rule: AutomationRuleDto,
    action: AutomationRuleDto['actions'][number],
    event: AutomationWriteEvent,
    execute: AutomationWriteExecutor,
    publishNotify: (rule: AutomationRuleDto, message: string, pk: unknown) => Promise<void>,
  ): Promise<void> {
    if (action.type === 'set_property') {
      if (!action.column || event.op === 'delete') return;
      const pk = event.pk ?? event.row['id'] ?? event.row['_id'];
      if (pk === undefined || pk === null) return;
      await execute(event.table, { [action.column]: action.value ?? null }, { id: pk });
      return;
    }
    if (action.type === 'notify') {
      await publishNotify(rule, action.message ?? rule.name, event.pk ?? event.row['id']);
      return;
    }
    if (action.type === 'webhook' && action.url) {
      await this.postWebhook(action.url, rule, event);
    }
  }

  /**
   * @brief POST the webhook to a resolve-validated, redirect-proof public HTTPS target.
   *
   * @par Vulnerability (CWE-918 Server-Side Request Forgery)
   * The previous guard inspected only the URL's literal hostname against a regex
   * denylist and then called `fetch(url)` with the default `redirect: 'follow'`.
   * Two bypasses followed: (1) a public-looking host could 3xx-redirect to
   * `http://169.254.169.254/` or an in-cluster service (`http://vault:8200`),
   * which undici silently followed WITHOUT re-validation; (2) a hostname that
   * merely *resolves* to an internal IP — or an IPv4-mapped-IPv6 literal — passed
   * the string-only denylist. The query-router could thus be coerced into
   * reaching the cloud-metadata endpoint and internal-only services.
   *
   * @par Remediation
   * `assertPublicHttpsTarget` enforces https, validates literal IPs (unmapping
   * IPv4-mapped-IPv6), and for hostnames DNS-resolves and refuses if ANY resolved
   * address is non-public (fail-closed on resolution failure). The fetch sets
   * `redirect: 'error'` so a 3xx to an unvalidated internal target fails delivery
   * rather than being followed. Residual: a sub-millisecond DNS-rebind between
   * resolve and connect is not closed here (Node global fetch re-resolves at
   * dial); the Go push dispatcher pins the connected IP for its equivalent path.
   * Engine-agnostic — applies regardless of which DB engine fired the automation.
   *
   * @see https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html
   * @see https://cwe.mitre.org/data/definitions/918.html
   */
  private async postWebhook(url: string, rule: AutomationRuleDto, event: AutomationWriteEvent): Promise<void> {
    await this.assertPublicHttpsTarget(url);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), WEBHOOK_TIMEOUT_MS);
    try {
      await fetch(url, {
        method: 'POST',
        redirect: 'error',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          rule: { id: rule.id, name: rule.name },
          dbId: event.dbId, table: event.table, op: event.op,
          pk: event.pk ?? null, ts: new Date().toISOString(),
        }),
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Reject any webhook URL that is not a public HTTPS endpoint (CWE-918). A
   * literal IP is validated directly; a hostname is DNS-resolved and rejected if
   * any resolved address is non-public, so a public-looking name pointing at an
   * internal/metadata IP cannot pass.
   */
  private async assertPublicHttpsTarget(rawUrl: string): Promise<void> {
    const parsed = new URL(rawUrl);
    if (parsed.protocol !== 'https:') {
      throw new Error(`webhook target rejected (https only): ${parsed.protocol}`);
    }
    const host = parsed.hostname.replace(/^\[|\]$/g, ''); // strip IPv6 brackets
    if (isIP(host)) {
      if (isPrivateAddress(host)) {
        throw new Error(`webhook target rejected (non-public address): ${host}`);
      }
      return;
    }
    let records: Array<{ address: string }>;
    try {
      records = await lookup(host, { all: true });
    } catch {
      throw new Error(`webhook target rejected (unresolvable host): ${host}`);
    }
    if (records.length === 0 || records.some((r) => isPrivateAddress(r.address))) {
      throw new Error(`webhook target rejected (resolves to non-public address): ${host}`);
    }
  }

  private async getPool(): Promise<Pool> {
    if (!this.pool) {
      const connectionString = this.config.get<string>('DATABASE_URL');
      if (!connectionString) throw new Error('DATABASE_URL missing for automation rules');
      this.pool = new Pool({ connectionString, max: 2, idleTimeoutMillis: 30_000 });
    }
    if (!this.tableReady) {
      await this.pool.query(
        `CREATE TABLE IF NOT EXISTS automation_rules (
           tenant_id text NOT NULL,
           db_id uuid NOT NULL,
           rules jsonb NOT NULL DEFAULT '[]'::jsonb,
           updated_at timestamptz NOT NULL DEFAULT now(),
           PRIMARY KEY (tenant_id, db_id)
         )`,
      );
      this.tableReady = true;
    }
    return this.pool;
  }
}

/** Tiny server-side condition evaluator over the written row. Exported for
 *  unit tests. Unknown columns make every operator but is_empty false. */
export function evaluateCondition(
  row: Record<string, unknown>,
  condition: { column: string; operator: string; value?: unknown },
): boolean {
  const value = row[condition.column];
  const empty = value === undefined || value === null || value === '';
  switch (condition.operator) {
    case 'is_empty': return empty;
    case 'is_not_empty': return !empty;
    case 'equals': return looseEquals(value, condition.value);
    case 'not_equals': return !looseEquals(value, condition.value);
    case 'contains':
      return stringify(value ?? '').toLowerCase().includes(stringify(condition.value ?? '').toLowerCase());
    case 'greater_than': return Number(value) > Number(condition.value);
    case 'less_than': return Number(value) < Number(condition.value);
    default: return false;
  }
}

/** Stable text form of any condition operand. Primitives match `String(x)`
 *  exactly (the normal case); objects serialise to JSON instead of collapsing
 *  to the unhelpful `[object Object]`. */
function stringify(value: unknown): string {
  if (value !== null && typeof value === 'object') return JSON.stringify(value);
  return String(value);
}

function looseEquals(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  // numeric strings vs numbers (engines disagree on wire types)
  if (a !== null && b !== null && a !== undefined && b !== undefined) {
    return stringify(a) === stringify(b);
  }
  return false;
}
