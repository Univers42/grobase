/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   automations.controller.ts                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/10 12:00:00 by dlesieur          #+#    #+#             */
/*                                                +#+#+#+#+#+   +#+           */
/* ************************************************************************** */

import { Body, Controller, Get, Param, ParseUUIDPipe, Put, UseGuards } from '@nestjs/common';
import { ApiOperation, ApiParam, ApiTags } from '@nestjs/swagger';
import {
  AuthGuard, CurrentIdentity, CurrentUser, UserContext, VerifiedRequestIdentity,
} from '@mini-baas/common';
import { AutomationsService } from './automations.service';
import { QueryService } from './query.service';
import { PutAutomationsDto, AutomationRuleDto } from './dto/automations.dto';

// Root-mounted like the other query controllers: Kong strips `/query/v1`, so
// this serves the public `GET|PUT /query/v1/:dbId/automations`.
@ApiTags('query')
@Controller()
@UseGuards(AuthGuard)
export class AutomationsController {
  constructor(
    private readonly automations: AutomationsService,
    private readonly query: QueryService,
  ) {}

  @Get(':dbId/automations')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiOperation({ summary: 'List the automation rules stored for a registered database' })
  async list(
    @CurrentUser() user: UserContext,
    @CurrentIdentity() identity: VerifiedRequestIdentity,
    @Param('dbId', ParseUUIDPipe) dbId: string,
  ): Promise<{ rules: AutomationRuleDto[] }> {
    const tenantId = identity?.tenantId ?? user.id;
    await this.query.resolveConnection(dbId, tenantId); // tenant-scope gate (404/403 on foreign mounts)
    return { rules: await this.automations.listRules(tenantId, dbId) };
  }

  @Put(':dbId/automations')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiOperation({
    summary: 'Replace the automation rules of a registered database',
    description:
      'PUT semantics: the body is the FULL rule set. Rules fire server-side ' +
      'after every successful write (any client), with loop safety (follow-up ' +
      'writes never re-trigger) and HTTPS-only SSRF-guarded webhooks.',
  })
  async put(
    @CurrentUser() user: UserContext,
    @CurrentIdentity() identity: VerifiedRequestIdentity,
    @Param('dbId', ParseUUIDPipe) dbId: string,
    @Body() dto: PutAutomationsDto,
  ): Promise<{ rules: AutomationRuleDto[] }> {
    const tenantId = identity?.tenantId ?? user.id;
    await this.query.resolveConnection(dbId, tenantId); // tenant-scope gate
    return { rules: await this.automations.putRules(tenantId, dbId, dto.rules) };
  }
}
