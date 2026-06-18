/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   bundles.service.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/10 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/10 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable } from '@nestjs/common';
import { PostgresService } from '@mini-baas/database';

/**
 * Serializes the live permission store into the PolicyBundle JSON the Rust
 * data-plane evaluator deserializes (data-plane-server/src/abac.rs):
 *
 *   PolicyBundle { user_roles: Vec<UserRole>, policies: Vec<Policy> }
 *   UserRole     { user_id, role_id, expires_at: Option<DateTime<Utc>> }
 *   Policy       { role_id, resource_type, resource_name, actions: Vec<String>,
 *                  effect: "allow"|"deny", priority: i32, conditions: Option<Value> }
 *
 * Field names/casing MUST stay snake_case to match the serde derive. Extra
 * top-level keys (generated_at) are safe: serde ignores unknown fields.
 */

export interface BundleUserRole {
  user_id: string;
  role_id: string;
  expires_at: string | null;
}

export interface BundlePolicy {
  role_id: string;
  resource_type: string;
  resource_name: string;
  actions: string[];
  effect: 'allow' | 'deny';
  priority: number;
  conditions: Record<string, unknown> | null;
}

export interface PolicyBundle {
  generated_at: string;
  user_roles: BundleUserRole[];
  policies: BundlePolicy[];
}

export interface RoleRow {
  id: string;
  name: string;
  description: string | null;
  metadata: Record<string, unknown>;
}

@Injectable()
export class BundlesService {
  constructor(private readonly pg: PostgresService) {}

  /** Active user→role assignments + every policy, in abac.rs PolicyBundle shape. */
  async latest(): Promise<PolicyBundle> {
    const [userRoles, policies] = await Promise.all([
      this.pg.adminQuery<BundleUserRole>(
        `SELECT ur.user_id::text AS user_id,
                ur.role_id::text AS role_id,
                to_char(ur.expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS expires_at
           FROM public.user_roles ur
          WHERE ur.expires_at IS NULL OR ur.expires_at > now()
          ORDER BY ur.user_id, ur.role_id`,
      ),
      this.pg.adminQuery<BundlePolicy>(
        `SELECT rp.role_id::text AS role_id,
                rp.resource_type,
                rp.resource_name,
                rp.actions,
                rp.effect,
                rp.priority,
                rp.conditions
           FROM public.resource_policies rp
          ORDER BY rp.priority DESC, rp.resource_type, rp.resource_name`,
      ),
    ]);
    return {
      generated_at: new Date().toISOString(),
      user_roles: userRoles,
      policies,
    };
  }

  /** All roles (id/name/description/metadata) — rows of the admin matrix UI. */
  async roles(): Promise<RoleRow[]> {
    return this.pg.adminQuery<RoleRow>(
      `SELECT r.id::text AS id, r.name, r.description, r.metadata
         FROM public.roles r
        ORDER BY r.name`,
    );
  }
}
