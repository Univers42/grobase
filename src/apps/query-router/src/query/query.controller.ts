/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.controller.ts                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 22:30:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  Body,
  Controller,
  Get,
  Headers,
  Param,
  ParseUUIDPipe,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiParam } from '@nestjs/swagger';
import {
  AuthGuard,
  CurrentIdentity,
  CurrentUser,
  UserContext,
  VerifiedRequestIdentity,
} from '@mini-baas/common';
import { QueryService } from './query.service';
import { ExecuteQueryDto } from './dto/query.dto';
import type { Request } from 'express';

/**
 * Caller IP for the ABAC PDP's ip_cidr conditions — SAME precedence as
 * audit.interceptor.ts: first X-Forwarded-For hop → req.ip → socket address.
 * Returns undefined when none is derivable (conditions then can't match an
 * ip_cidr policy, which fails closed by design).
 */
function clientIp(req: Request): string | undefined {
  const xff = (req.headers['x-forwarded-for'] as string | undefined)?.split(',')[0]?.trim();
  return xff || req.ip || req.socket?.remoteAddress || undefined;
}

@ApiTags('query')
// Root-mounted: the gateway prefix `/query/v1` is already stripped by Kong
// (strip_path), so the controller serves the remainder (`/:dbId/tables/:table`)
// at root — matching engines.controller (`@Controller('engines')` → /engines).
// A `query` prefix here would double-count the stripped segment and 404.
@Controller()
@UseGuards(AuthGuard)
export class QueryController {
  constructor(private readonly service: QueryService) {}

  @Post(':dbId/tables/:table')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiParam({ name: 'table', description: 'Table or collection name' })
  @ApiOperation({ summary: 'Execute a query on a registered database' })
  async execute(
    @CurrentUser() user: UserContext,
    @CurrentIdentity() identity: VerifiedRequestIdentity,
    @Param('dbId', ParseUUIDPipe) dbId: string,
    @Param('table') table: string,
    @Body() dto: ExecuteQueryDto,
    @Headers('idempotency-key') idempotencyKey: string | undefined,
    @Req() request: Request,
  ) {
    if (idempotencyKey && !dto.idempotencyKey) dto.idempotencyKey = idempotencyKey;
    return this.service.executeQuery(dbId, table, user.id, dto, {
      requestId: request.requestId,
      identity,
      ip: clientIp(request),
    });
  }

  @Get(':dbId/tables')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiOperation({ summary: 'List tables/collections in a registered database' })
  async listTables(
    @CurrentUser() user: UserContext,
    @CurrentIdentity() identity: VerifiedRequestIdentity,
    @Param('dbId', ParseUUIDPipe) dbId: string,
  ) {
    return this.service.listTables(dbId, user.id, identity);
  }
}
