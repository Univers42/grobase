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

const PRIVATE_HOST_PATTERNS = [
  /^localhost$/i, /^127\./, /^10\./, /^192\.168\./, /^169\.254\./,
  /^172\.(1[6-9]|2\d|3[01])\./, /^0\./, /^\[?::1\]?$/, /^\[?f[cd][0-9a-f]{2}:/i,
  /\.local$/i, /^[^.]+$/, // bare hostnames (docker service names) are internal
];

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

  /** HTTPS-only + private-address guard; 5s timeout; no retry. */
  private async postWebhook(url: string, rule: AutomationRuleDto, event: AutomationWriteEvent): Promise<void> {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' || PRIVATE_HOST_PATTERNS.some((pattern) => pattern.test(parsed.hostname))) {
      throw new Error(`webhook target rejected (https + public hosts only): ${parsed.hostname}`);
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), WEBHOOK_TIMEOUT_MS);
    try {
      await fetch(url, {
        method: 'POST',
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
      return String(value ?? '').toLowerCase().includes(String(condition.value ?? '').toLowerCase());
    case 'greater_than': return Number(value) > Number(condition.value);
    case 'less_than': return Number(value) < Number(condition.value);
    default: return false;
  }
}

function looseEquals(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  // numeric strings vs numbers (engines disagree on wire types)
  if (a !== null && b !== null && a !== undefined && b !== undefined) {
    return String(a) === String(b);
  }
  return false;
}
