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
import {
  HealthCheck,
  HealthCheckService,
  HealthIndicatorResult,
  HealthIndicatorService,
} from '@nestjs/terminus';
import { ApiTags, ApiOperation } from '@nestjs/swagger';

/**
 * A service registered as a health indicator. It reports its own readiness
 * as a boolean; the controller maps that to a Terminus result keyed by the
 * service's class name.
 */
export interface HealthReportingIndicator {
  isHealthy(): Promise<boolean>;
}

/**
 * Generic liveness + readiness health controller.
 * Apps register custom health indicators via HealthModule.forRoot().
 */
@ApiTags('health')
@Controller('health')
export class HealthController {
  constructor(
    private readonly health: HealthCheckService,
    private readonly indicators: HealthReportingIndicator[],
    private readonly indicatorService: HealthIndicatorService,
  ) {}

  @Get('live')
  @ApiOperation({ summary: 'Liveness probe' })
  live() {
    return { status: 'ok' };
  }

  @Get('ready')
  @HealthCheck()
  @ApiOperation({ summary: 'Readiness probe — checks all registered health indicators' })
  ready() {
    return this.health.check(
      this.indicators.map((indicator) => () => this.checkIndicator(indicator)),
    );
  }

  private async checkIndicator(
    indicator: HealthReportingIndicator,
  ): Promise<HealthIndicatorResult> {
    const key = indicator.constructor.name;
    const session = this.indicatorService.check(key);
    const healthy = await indicator.isHealthy();
    return healthy ? session.up() : session.down();
  }
}
