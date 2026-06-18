/**
 * Analytics Controller
 */
import { Controller, Get, Post, Body, Query } from '@nestjs/common';
import {
  ApiTags,
  ApiOperation,
  ApiOkResponse,
  ApiBearerAuth,
} from '@nestjs/swagger';
import { AnalyticsService, AnalyticsEvent } from './analytics.service';
import { Roles } from '../common';

@ApiTags('Analytics')
@Controller('analytics')
@ApiBearerAuth()
export class AnalyticsController {
  constructor(private readonly service: AnalyticsService) {}

  @Post('track')
  @ApiOperation({ summary: 'Track an analytics event' })
  async track(
    @Body()
    body: {
      eventType: string;
      data?: Record<string, any>;
      userId?: string;
    },
  ): Promise<{ success: boolean }> {
    await this.service.trackEvent({
      eventType: body.eventType,
      userId: body.userId,
      data: body.data || {},
      timestamp: new Date(),
    });
    return { success: true };
  }

  @Get('events')
  @Roles('ADMIN')
  @ApiOperation({ summary: 'Get events by type' })
  @ApiOkResponse({ description: 'List of events' })
  async getEvents(
    @Query('type') type: string,
    @Query('limit') limit?: number,
  ): Promise<AnalyticsEvent[]> {
    return this.service.getEventsByType(type, limit);
  }

  @Get('stats')
  @Roles('ADMIN')
  @ApiOperation({ summary: 'Get event statistics' })
  @ApiOkResponse({ description: 'Event statistics' })
  async getStats(
    @Query('days') days?: number,
  ): Promise<Record<string, number>> {
    return this.service.getEventStats(days);
  }
}
