/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   subscription.controller.ts                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Get, Param, Post, Query, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth, ApiSecurity } from '@nestjs/swagger';
import { AuthGuard, Roles, RolesGuard } from '@mini-baas/common';
import { SubscriptionService } from './subscription.service';
import { SubscribeDto } from '../dto/newsletter.dto';

@ApiTags('subscription')
@Controller()
@ApiSecurity('apikey')
export class SubscriptionController {
  constructor(private readonly service: SubscriptionService) {}

  @Post('subscribe')
  @ApiOperation({ summary: 'Subscribe an email to the newsletter' })
  async subscribe(@Body() dto: SubscribeDto) {
    return this.service.subscribe(dto.email, dto.firstName);
  }

  @Get('confirm/:token')
  @ApiOperation({ summary: 'Confirm subscription via token' })
  async confirm(@Param('token') token: string) {
    return this.service.confirm(token);
  }

  @Get('unsubscribe/:token')
  @ApiOperation({ summary: 'Unsubscribe via token' })
  async unsubscribe(@Param('token') token: string) {
    return this.service.unsubscribe(token);
  }

  @Get('admin/subscribers')
  @UseGuards(AuthGuard, RolesGuard)
  @Roles('service_role')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'List active subscribers (admin)' })
  async listSubscribers(
    @Query('limit') limit?: number,
    @Query('offset') offset?: number,
  ) {
    return this.service.getSubscribers(
      limit ? Number(limit) : undefined,
      offset ? Number(offset) : undefined,
    );
  }

  @Get('admin/stats')
  @UseGuards(AuthGuard, RolesGuard)
  @Roles('service_role')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Get subscriber stats (admin)' })
  async stats() {
    return this.service.getStats();
  }
}
