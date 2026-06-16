/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   events.controller.ts                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Get, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth, ApiSecurity } from '@nestjs/swagger';
import { AuthGuard, OptionalAuthGuard, Roles, RolesGuard } from '@mini-baas/common';
import { Request } from 'express';
import { EventsService } from './events.service';
import { TrackEventDto, QueryEventsDto, EventStatsDto } from './dto/events.dto';

@ApiTags('events')
@Controller('events')
@ApiSecurity('apikey')
export class EventsController {
  constructor(private readonly service: EventsService) {}

  /**
   * Track an analytics event.
   * Authenticated users get their userId auto-injected.
   */
  @Post()
  @UseGuards(OptionalAuthGuard)
  @ApiOperation({ summary: 'Track an analytics event' })
  async track(
    @Body() dto: TrackEventDto,
    @Req() req: Request,
  ) {
    await this.service.track({
      eventType: dto.eventType,
      userId: dto.userId ?? req.user?.id,
      data: dto.data ?? {},
      timestamp: new Date(),
    });
    return { tracked: true };
  }

  /**
   * Query events by type. Requires service_role.
   */
  @Get()
  @UseGuards(AuthGuard, RolesGuard)
  @Roles('service_role')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Query events by type (admin)' })
  async getEvents(@Query() query: QueryEventsDto) {
    const since = query.since ? new Date(query.since) : undefined;
    const limit = query.limit ? Number(query.limit) : undefined;
    return this.service.getByType(query.type, { since, limit });
  }

  /**
   * Aggregated event statistics over a time window.
   */
  @Get('stats')
  @UseGuards(AuthGuard, RolesGuard)
  @Roles('service_role')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Get event count statistics (admin)' })
  async getStats(@Query() query: EventStatsDto) {
    const days = query.days ? Number(query.days) : 7;
    return this.service.getStats(days, query.type);
  }

  /**
   * List all distinct event types.
   */
  @Get('types')
  @UseGuards(AuthGuard, RolesGuard)
  @Roles('service_role')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'List distinct event types (admin)' })
  async getTypes() {
    return this.service.getDistinctTypes();
  }
}
