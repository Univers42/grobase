import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PostgresService } from '@mini-baas/database';
import { DecidePermissionDto } from './dto/decision.dto';

export interface FieldMask {
  hide?: string[];
  redact?: Record<string, string>;
}

export interface PermissionDecision {
  allow: boolean;
  reason: string;
  mask?: FieldMask;
  mode: PermissionMode;
}

interface PermissionRow {
  has_permission: boolean;
}

interface ConditionsRow {
  conditions: Record<string, unknown> | null;
}

/**
 * Permission model.
 *
 * - `abac` (default): roles match the request AND JSONB conditions on
 *   resource_policies are evaluated; field masks (hide/redact) are returned
 *   on allow.
 * - `rbac`: roles match the request; no conditions evaluated, no masks
 *   returned. Simpler, faster, no JSONB scan per request. Use when product
 *   doesn't need attribute-level decisions.
 *
 * The two modes are mutually exclusive — set `PERMISSION_MODE` once at
 * deploy time. Switching mid-stream invalidates any per-user cached
 * decisions in the query-router.
 */
export type PermissionMode = 'abac' | 'rbac';

@Injectable()
export class DecisionsService {
  private readonly logger = new Logger(DecisionsService.name);
  private readonly mode: PermissionMode;
  // B1: when ON, the PDP passes p_conditions_enabled=true to has_permission so
  // the stored conditions JSONB (time_window/ip_cidr/aal/owner/resource_id)
  // actually GATE a policy match. OFF (default) ⇒ has_permission ignores
  // conditions exactly as in migration 007 — byte-parity with today.
  private readonly conditionsEnabled: boolean;

  constructor(
    private readonly pg: PostgresService,
    config: ConfigService,
  ) {
    const raw = (config.get<string>('PERMISSION_MODE', 'abac') ?? 'abac').toLowerCase();
    this.mode = raw === 'rbac' ? 'rbac' : 'abac';
    // Mirror the PERMISSION_MODE pattern: a single boolean, read once at boot.
    // Conditions only make sense in abac mode (rbac has no JSONB scan at all).
    this.conditionsEnabled =
      this.mode === 'abac' &&
      ['1', 'true', 'yes', 'on'].includes(
        (config.get<string>('PERMISSION_CONDITIONS_ENABLED', '0') ?? '0').toLowerCase(),
      );
    this.logger.log(
      `DecisionsService running in mode=${this.mode} conditions=${this.conditionsEnabled ? 'on' : 'off'}`,
    );
  }

  async decide(dto: DecidePermissionDto): Promise<PermissionDecision> {
    const action = this.actionForOp(dto.op);
    const attrs = this.buildAttrs(dto);
    const resourceId = this.resourceId(dto);
    const rows = await this.pg.adminQuery<PermissionRow>(
      `SELECT public.has_permission($1::uuid, $2, $3, $4, $5::jsonb, $6, $7) AS has_permission`,
      [
        dto.user.id,
        dto.resource_type,
        dto.resource_name,
        action,
        JSON.stringify(attrs),
        this.conditionsEnabled,
        resourceId,
      ],
    );
    const allow = rows[0]?.has_permission ?? false;
    const decision: PermissionDecision = {
      allow,
      reason: allow
        ? `Allowed by ${this.mode.toUpperCase()} policy`
        : `Denied by ${this.mode.toUpperCase()} policy`,
      mode: this.mode,
    };
    // RBAC mode short-circuits before mask resolution — that's the whole
    // point of the simpler mode (no JSONB conditions, no per-field masks).
    if (allow && this.mode === 'abac') {
      const mask = await this.resolveMask(
        dto.user.id,
        dto.resource_type,
        dto.resource_name,
        action,
      );
      if (mask) decision.mask = mask;
    }
    this.logger.debug(
      `${this.mode.toUpperCase()} decision user=${dto.user.id} resource=${dto.resource_type}/${dto.resource_name} op=${dto.op} allow=${allow}`,
    );
    return decision;
  }

  /**
   * Build the request-attribute bag the SQL evaluator (auth.eval_conditions)
   * sees: user_id, tenant_id, aal, ip, resource_id. The caller (query-router)
   * supplies ip/aal/resource_id via {@link DecidePermissionDto.attributes}; we
   * normalize them onto reserved keys so the SQL side stays simple. Stable shape
   * even when conditions are OFF (the function ignores it then).
   */
  private buildAttrs(dto: DecidePermissionDto): Record<string, unknown> {
    const a = dto.attributes ?? {};
    const out: Record<string, unknown> = { ...a };
    out['user_id'] = dto.user.id;
    if (dto.tenant_id) out['tenant_id'] = dto.tenant_id;
    // aal: passthrough from attributes (query-router/JWT claim), default aal1.
    out['aal'] = typeof a['aal'] === 'string' && a['aal'] ? a['aal'] : 'aal1';
    const rid = this.resourceId(dto);
    if (rid) out['resource_id'] = rid;
    return out;
  }

  /** Resolve the per-instance subject id from the dedicated field or attrs. */
  private resourceId(dto: DecidePermissionDto): string | null {
    if (typeof dto.resource_id === 'string' && dto.resource_id) return dto.resource_id;
    const fromAttrs = dto.attributes?.['resource_id'];
    return typeof fromAttrs === 'string' && fromAttrs ? fromAttrs : null;
  }

  private actionForOp(op: DecidePermissionDto['op']): string {
    if (op === 'list' || op === 'get') return 'select';
    if (op === 'upsert') return 'update';
    return op;
  }

  private async resolveMask(
    userId: string,
    resourceType: string,
    resourceName: string,
    action: string,
  ): Promise<FieldMask | undefined> {
    const rows = await this.pg.adminQuery<ConditionsRow>(
      `SELECT rp.conditions
         FROM public.resource_policies rp
         JOIN public.user_roles ur ON ur.role_id = rp.role_id
        WHERE ur.user_id = $1::uuid
          AND (ur.expires_at IS NULL OR ur.expires_at > now())
          AND (rp.resource_type = $2 OR rp.resource_type = '*')
          AND (rp.resource_name = $3 OR rp.resource_name = '*')
          AND $4 = ANY(rp.actions)
          AND rp.effect = 'allow'
        ORDER BY
          -- B3 tiebreak: a table-specific mask wins over a wildcard mask, then
          -- by priority. Exact resource_name beats '*' at any priority so a
          -- mask attached to one table is not shadowed by a broad wildcard row.
          (rp.resource_name = $3) DESC,
          (rp.resource_type = $2) DESC,
          rp.priority DESC
        LIMIT 1`,
      [userId, resourceType, resourceName, action],
    );
    return this.maskFromConditions(rows[0]?.conditions);
  }

  private maskFromConditions(
    conditions: Record<string, unknown> | null | undefined,
  ): FieldMask | undefined {
    if (!conditions) return undefined;
    const maskValue = conditions['mask'] ?? conditions['field_mask'];
    if (!maskValue || typeof maskValue !== 'object' || Array.isArray(maskValue)) return undefined;
    const mask = maskValue as Record<string, unknown>;
    const hide = Array.isArray(mask['hide'])
      ? mask['hide'].filter(
          (field): field is string => typeof field === 'string' && field.length > 0,
        )
      : undefined;
    const redact = this.stringRecord(mask['redact']);
    if (!hide && !redact) return undefined;
    return { hide, redact };
  }

  private stringRecord(value: unknown): Record<string, string> | undefined {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
    const out: Record<string, string> = {};
    for (const [key, replacement] of Object.entries(value as Record<string, unknown>)) {
      if (typeof replacement === 'string') out[key] = replacement;
    }
    return Object.keys(out).length ? out : undefined;
  }
}
