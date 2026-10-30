/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   probe.controller.ts                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Controller, Get, Param, ParseUUIDPipe, UseGuards } from '@nestjs/common';
import { ApiOperation, ApiParam, ApiTags } from '@nestjs/swagger';
import {
  AuthGuard,
  CurrentIdentity,
  CurrentUser,
  UserContext,
  VerifiedRequestIdentity,
} from '@mini-baas/common';
import { ProbeService, ProbeResponse } from './probe.service';

// Root-mounted like SchemaController: Kong strips `/query/v1` (strip_path), so
// this serves the public `GET /query/v1/:dbId/probe` as `GET /:dbId/probe`.
@ApiTags('query')
@Controller()
@UseGuards(AuthGuard)
export class ProbeController {
  constructor(private readonly service: ProbeService) {}

  @Get(':dbId/probe')
  @ApiParam({ name: 'dbId', type: 'string', format: 'uuid' })
  @ApiOperation({
    summary: 'Live engine probe: server version and the TLS posture of the pool’s connection',
    description:
      'Cached per tenant+mount+revision. Platform mounts report ' +
      '`server_version: "platform"`; static mounts 404; returns 404 when the ' +
      "data plane's probe is disabled.",
  })
  async probe(
    @CurrentUser() user: UserContext,
    @CurrentIdentity() identity: VerifiedRequestIdentity,
    @Param('dbId', ParseUUIDPipe) dbId: string,
  ): Promise<ProbeResponse> {
    return this.service.probe(dbId, user.id, identity);
  }
}
