/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   policies.service.ts                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, NotFoundException } from '@nestjs/common';
import { PostgresService } from '@mini-baas/database';
import { CreatePolicyDto } from './dto/policy.dto';

export interface PolicyRow {
  id: string;
  role_id: string;
  resource_type: string;
  resource_name: string;
  actions: string[];
  conditions: Record<string, unknown>;
  effect: string;
  priority: number;
}

@Injectable()
export class PoliciesService {
  constructor(private readonly pg: PostgresService) {}

  async list(): Promise<PolicyRow[]> {
    return this.pg.adminQuery<PolicyRow>(
      `SELECT id, role_id, resource_type, resource_name, actions, conditions, effect, priority
         FROM resource_policies ORDER BY priority DESC, resource_type, resource_name`,
    );
  }

  async findByRole(roleId: string): Promise<PolicyRow[]> {
    return this.pg.adminQuery<PolicyRow>(
      `SELECT id, role_id, resource_type, resource_name, actions, conditions, effect, priority
         FROM resource_policies WHERE role_id = $1 ORDER BY priority DESC`,
      [roleId],
    );
  }

  async create(dto: CreatePolicyDto): Promise<PolicyRow> {
    const rows = await this.pg.adminQuery<PolicyRow>(
      `INSERT INTO resource_policies (role_id, resource_type, resource_name, actions, conditions, effect, priority)
       VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7)
       RETURNING id, role_id, resource_type, resource_name, actions, conditions, effect, priority`,
      [
        dto.role_id,
        dto.resource_type,
        dto.resource_name,
        dto.actions,
        JSON.stringify(dto.conditions ?? {}),
        dto.effect,
        dto.priority ?? 0,
      ],
    );
    const row = rows[0];
    if (!row) {
      throw new NotFoundException('Policy was not created');
    }
    return row;
  }

  async remove(id: string): Promise<{ deleted: boolean }> {
    const rows = await this.pg.adminQuery<{ id: string }>(
      `DELETE FROM resource_policies WHERE id = $1 RETURNING id`,
      [id],
    );
    if (!rows.length) {
      throw new NotFoundException('Policy not found');
    }
    return { deleted: true };
  }
}
