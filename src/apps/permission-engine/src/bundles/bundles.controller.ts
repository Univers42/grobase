/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   bundles.controller.ts                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/10 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/10 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Delete, Get, Param, ParseUUIDPipe, Post, UseGuards } from '@nestjs/common';
import { ApiOperation, ApiParam, ApiSecurity, ApiTags } from '@nestjs/swagger';
import { ServiceTokenGuard } from '@mini-baas/common';
import { PoliciesService } from '../policies/policies.service';
import { CreatePolicyDto } from '../policies/dto/policy.dto';
import { BundlesService } from './bundles.service';

/**
 * Service-token surface for permission distribution + admin tooling.
 *
 * - GET  /permissions/bundles/latest    — PolicyBundle for the Rust in-process
 *   evaluator (data-plane-router `DATA_PLANE_PERMISSION_BUNDLE_URL`).
 * - GET  /permissions/bundles/roles     — role catalogue (matrix rows).
 * - GET  /permissions/bundles/policies  — policy rows WITH ids (matrix cells).
 * - POST/DELETE …/policies              — matrix mutations.
 *
 * Everything is guarded like /permissions/decide (ServiceTokenGuard:
 * X-Service-Token = ADAPTER_REGISTRY_SERVICE_TOKEN + X-Tenant-Id), because the
 * /policies controller's AuthGuard envelope is unreachable for external
 * service callers in strict identity mode.
 */
@ApiTags('bundles')
@Controller('permissions/bundles')
@UseGuards(ServiceTokenGuard)
export class BundlesController {
  constructor(
    private readonly bundles: BundlesService,
    private readonly policies: PoliciesService,
  ) {}

  @Get('latest')
  @ApiSecurity('service-token')
  @ApiOperation({ summary: 'Policy bundle (user_roles + policies) for the Rust ABAC evaluator' })
  latest() {
    return this.bundles.latest();
  }

  @Get('roles')
  @ApiSecurity('service-token')
  @ApiOperation({ summary: 'All roles with id/name/description/metadata (admin matrix rows)' })
  async roles() {
    return { roles: await this.bundles.roles() };
  }

  @Get('policies')
  @ApiSecurity('service-token')
  @ApiOperation({ summary: 'All resource policies including ids (admin matrix cells)' })
  async listPolicies() {
    return { policies: await this.policies.list() };
  }

  @Post('policies')
  @ApiSecurity('service-token')
  @ApiOperation({ summary: 'Create a resource policy (admin matrix mutation)' })
  createPolicy(@Body() dto: CreatePolicyDto) {
    return this.policies.create(dto);
  }

  @Delete('policies/:id')
  @ApiSecurity('service-token')
  @ApiParam({ name: 'id', type: 'string', format: 'uuid' })
  @ApiOperation({ summary: 'Delete a resource policy by id' })
  removePolicy(@Param('id', ParseUUIDPipe) id: string) {
    return this.policies.remove(id);
  }
}
