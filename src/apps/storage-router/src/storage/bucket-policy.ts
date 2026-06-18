/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   bucket-policy.ts                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// A1 (Track-A → 100%) — bucket-level ABAC policy for the storage plane. A
// per-bucket allow/deny rule the storage authz consults BEFORE the owner-scoped
// S3 op runs. It LAYERS ON TOP of the existing owner-prefix isolation (it never
// widens it): the owner prefix already guarantees a caller can only ever touch
// `<userId>/…`; this adds a per-bucket gate (e.g. a read-only bucket, or a bucket
// restricted to one role) on top of that.
//
// ## Parity (flag OFF — the default)
//
// `BucketPolicy.fromConfig` returns `undefined` when STORAGE_BUCKET_POLICY_ENABLED
// is OFF, so the call site never constructs it, never parses, never consults — every
// request takes the exact pre-policy path (owner-scope only). Observably byte-parity
// with the pre-policy storage-router.
//
// ## Configuration (STORAGE_BUCKET_POLICY, JSON; only read when the flag is ON)
//
//   {
//     "<bucket>": {
//       "read":  ["role:authenticated", "user:<id>"],   // optional allow-list
//       "write": ["role:service_role"],                  // optional allow-list
//       "deny":  ["user:<id>"]                           // optional deny-list (wins)
//     },
//     "*": { ... default rule for buckets with no explicit entry ... }
//   }
//
// A principal token is one of `role:<role>`, `user:<userId>`, or the literal `*`
// (everyone). DENY beats ALLOW. A bucket with NO matching rule (and no "*" rule)
// is ALLOWED — the flag adds restriction only where a rule is declared, so turning
// the flag on with an empty/partial map is still effectively-parity for unlisted
// buckets, never a surprise lock-out of the whole plane.

export type BucketAction = 'read' | 'write';

/** The authz subject the policy is evaluated against (a subset of UserContext). */
export interface PolicyPrincipal {
  userId: string;
  role: string;
}

interface BucketRule {
  read?: string[];
  write?: string[];
  deny?: string[];
}

type PolicyMap = Record<string, BucketRule>;

/**
 * Per-bucket allow/deny evaluator. Constructed ONLY when the
 * STORAGE_BUCKET_POLICY_ENABLED flag is ON (see `fromConfig`). DENY wins; a bucket
 * with no rule (and no "*" rule) is allowed; an action with no allow-list on a
 * matched rule is allowed (the rule restricts only the actions it names).
 */
export class BucketPolicy {
  private constructor(private readonly rules: PolicyMap) {}

  /**
   * Parse the policy map IFF the flag is ON. Returns `undefined` when OFF (default)
   * so the call site stays byte-parity. A malformed STORAGE_BUCKET_POLICY is a hard
   * boot error (fail-closed on config, not silently open) — but only ever reached
   * once the operator has explicitly opted in via the flag.
   */
  static fromConfig(env: NodeJS.ProcessEnv = process.env): BucketPolicy | undefined {
    if (!isTruthy(env['STORAGE_BUCKET_POLICY_ENABLED'])) return undefined;
    const raw = (env['STORAGE_BUCKET_POLICY'] ?? '{}').trim() || '{}';
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch (err) {
      throw new Error(`STORAGE_BUCKET_POLICY is not valid JSON: ${(err as Error).message}`);
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      throw new Error('STORAGE_BUCKET_POLICY must be a JSON object of { <bucket>: rule }');
    }
    return new BucketPolicy(parsed as PolicyMap);
  }

  /** True iff `principal` may perform `action` on `bucket`. */
  allows(bucket: string, action: BucketAction, principal: PolicyPrincipal): boolean {
    const rule = this.rules[bucket] ?? this.rules['*'];
    if (!rule) return true; // no rule for this bucket → owner-scope governs alone

    const tokens = principalTokens(principal);
    if (matchesAny(rule.deny, tokens)) return false; // DENY wins

    const allow = action === 'read' ? rule.read : rule.write;
    if (!allow || allow.length === 0) return true; // action not restricted by this rule
    return matchesAny(allow, tokens);
  }

  /** Number of buckets with an explicit rule — a gauge a gate can read. */
  ruleCount(): number {
    return Object.keys(this.rules).length;
  }
}

/** The principal tokens a rule list is matched against. */
function principalTokens(p: PolicyPrincipal): Set<string> {
  return new Set<string>(['*', `user:${p.userId}`, `role:${p.role}`]);
}

function matchesAny(list: string[] | undefined, tokens: Set<string>): boolean {
  if (!list || list.length === 0) return false;
  return list.some((entry) => tokens.has(entry.trim()));
}

function isTruthy(value: string | undefined): boolean {
  if (!value) return false;
  return ['1', 'true', 'yes', 'on'].includes(value.trim().toLowerCase());
}
