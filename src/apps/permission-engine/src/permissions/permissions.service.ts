/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   permissions.service.ts                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger } from '@nestjs/common';
import { PostgresService } from '@mini-baas/database';

export interface PermissionResult {
  allowed: boolean;
  reason?: string;
}

interface RoleRow {
  name: string;
}

@Injectable()
export class PermissionsService {
  private readonly logger = new Logger(PermissionsService.name);

  constructor(private readonly pg: PostgresService) {}

  /**
   * Evaluate ABAC permission check using the SQL function from migration 007.
   */
  async check(
    userId: string,
    resourceType: string,
    resourceName: string,
    action: string,
  ): Promise<PermissionResult> {
    const rows = await this.pg.adminQuery<{ has_permission: boolean }>(
      `SELECT public.has_permission($1::uuid, $2, $3, $4) AS has_permission`,
      [userId, resourceType, resourceName, action],
    );

    const allowed = rows[0]?.has_permission ?? false;

    this.logger.debug(
      `Permission check: user=${userId} resource=${resourceType}/${resourceName} action=${action} → ${allowed}`,
    );

    return {
      allowed,
      reason: allowed ? undefined : 'Denied by ABAC policy',
    };
  }

  /**
   * Get all roles assigned to a user.
   */
  async getUserRoles(userId: string): Promise<string[]> {
    const rows = await this.pg.adminQuery<RoleRow>(
      `SELECT r.name FROM roles r
       JOIN user_roles ur ON ur.role_id = r.id
       WHERE ur.user_id = $1
         AND (ur.expires_at IS NULL OR ur.expires_at > now())`,
      [userId],
    );
    return rows.map((r) => r.name);
  }

  /**
   * Assign a role to a user.
   */
  async assignRole(
    targetUserId: string,
    roleName: string,
    grantedBy: string,
  ): Promise<{ assigned: boolean }> {
    await this.pg.adminQuery(
      `INSERT INTO user_roles (user_id, role_id, granted_by)
       SELECT $1::uuid, r.id, $3::uuid
         FROM roles r WHERE r.name = $2
       ON CONFLICT (user_id, role_id) DO NOTHING`,
      [targetUserId, roleName, grantedBy],
    );
    return { assigned: true };
  }

  /**
   * Remove a role from a user.
   */
  async revokeRole(targetUserId: string, roleName: string): Promise<{ revoked: boolean }> {
    await this.pg.adminQuery(
      `DELETE FROM user_roles
       WHERE user_id = $1::uuid
         AND role_id = (SELECT id FROM roles WHERE name = $2)`,
      [targetUserId, roleName],
    );
    return { revoked: true };
  }
}
