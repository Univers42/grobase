/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   health.controller.ts                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 15:40:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:11 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Controller, Get, ServiceUnavailableException } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { OutboxRelayService } from './outbox-relay.service';

@ApiTags('health')
@Controller('health')
export class HealthController {
  constructor(private readonly relay: OutboxRelayService) {}

  @Get('live')
  @ApiOperation({ summary: 'Liveness probe' })
  live() {
    return { status: 'ok' };
  }

  @Get('ready')
  @ApiOperation({ summary: 'Readiness probe' })
  ready() {
    if (!this.relay.isReady()) {
      throw new ServiceUnavailableException('outbox relay dependencies are not ready');
    }
    return { status: 'ok' };
  }
}
