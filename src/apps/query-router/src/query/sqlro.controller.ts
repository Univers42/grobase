/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sqlro.controller.ts                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/07/12 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/07/12 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Param, ParseUUIDPipe, Post, UseGuards } from '@nestjs/common';
import { ApiOperation, ApiParam, ApiTags } from '@nestjs/swagger';
import {
  AuthGuard,
  CurrentIdentity,
  CurrentUser,
  UserContext,
  VerifiedRequestIdentity,
} from '@mini-baas/common';
import { SqlRoService } from './sqlro.service';
import { SqlRoDto } from './dto/sqlro.dto';

@ApiTags('query')
@Controller()
@UseGuards(AuthGuard)
export class SqlRoController {
  constructor(private readonly service: SqlRoService) {}

  @Post(':dbId/sql-ro')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiOperation({ summary: 'Run a read-only SQL query on a postgres mount (flag-gated)' })
  async run(
    @CurrentUser() user: UserContext,
    @CurrentIdentity() identity: VerifiedRequestIdentity,
    @Param('dbId', ParseUUIDPipe) dbId: string,
    @Body() dto: SqlRoDto,
  ) {
    const tenantId = identity?.tenantId ?? user.id;
    return this.service.run(dbId, tenantId, dto.sql);
  }
}
