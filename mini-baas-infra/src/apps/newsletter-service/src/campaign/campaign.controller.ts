/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   campaign.controller.ts                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Get, Post, Query, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth, ApiSecurity } from '@nestjs/swagger';
import { AuthGuard, CurrentUser, Roles, RolesGuard, UserContext } from '@mini-baas/common';
import { CampaignService } from './campaign.service';
import { SendCampaignDto } from '../dto/newsletter.dto';

@ApiTags('campaigns')
@Controller('admin/campaigns')
@UseGuards(AuthGuard, RolesGuard)
@Roles('service_role')
@ApiBearerAuth()
@ApiSecurity('apikey')
export class CampaignController {
  constructor(private readonly service: CampaignService) {}

  @Post('send')
  @ApiOperation({ summary: 'Send a campaign to all confirmed subscribers (admin)' })
  async send(
    @Body() dto: SendCampaignDto,
    @CurrentUser() user: UserContext,
  ) {
    return this.service.sendCampaign(dto.subject, dto.html, dto.text, user.id);
  }

  @Get('history')
  @ApiOperation({ summary: 'Get campaign send history (admin)' })
  async history(@Query('limit') limit?: number) {
    return this.service.getHistory(limit ? Number(limit) : undefined);
  }
}
