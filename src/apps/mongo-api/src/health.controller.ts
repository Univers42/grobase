/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   health.controller.ts                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Controller, Get } from '@nestjs/common';
import { HealthCheck, HealthCheckService } from '@nestjs/terminus';
import { ApiTags, ApiOperation } from '@nestjs/swagger';
import { MongoService } from '@mini-baas/database';

@ApiTags('health')
@Controller('health')
export class HealthController {
  constructor(
    private readonly health: HealthCheckService,
    private readonly mongo: MongoService,
  ) {}

  @Get('live')
  @ApiOperation({ summary: 'Liveness probe' })
  live() {
    return { status: 'ok' };
  }

  @Get()
  @HealthCheck()
  @ApiOperation({ summary: 'Legacy health — pings MongoDB' })
  legacyHealth() {
    return this.ready();
  }

  @Get('ready')
  @HealthCheck()
  @ApiOperation({ summary: 'Readiness probe — checks MongoDB connectivity' })
  ready() {
    return this.health.check([
      async () => {
        const ok = await this.mongo.isHealthy();
        return { mongodb: { status: ok ? 'up' : 'down' } };
      },
    ]);
  }
}
