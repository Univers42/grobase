/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sqlro.controller.ts                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/07/12 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/23 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Param, ParseUUIDPipe, Post, UseGuards } from '@nestjs/common';
import { ApiOperation, ApiParam, ApiTags } from '@nestjs/swagger';
import { AuthGuard, CurrentIdentity, VerifiedRequestIdentity } from '@mini-baas/common';
import { SqlRoService } from './sqlro.service';
import { SqlRoDto } from './dto/sqlro.dto';

@ApiTags('query')
@Controller()
@UseGuards(AuthGuard)
export class SqlRoController {
  constructor(private readonly service: SqlRoService) {}

  /**
   * Run read-only SQL on a mount owned by the caller's VERIFIED tenant. The tenant
   * comes from the identity envelope only — never a user-id fallback — so the
   * mount lookup is scoped to the credential, not to anything the caller names.
   */
  @Post(':dbId/sql-ro')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiOperation({ summary: 'Run a read-only SQL query on a postgres mount (flag-gated)' })
  async run(
    @CurrentIdentity() identity: VerifiedRequestIdentity,
    @Param('dbId', ParseUUIDPipe) dbId: string,
    @Body() dto: SqlRoDto,
  ) {
    return this.service.run(dbId, identity.tenantId, dto.sql);
  }
}
