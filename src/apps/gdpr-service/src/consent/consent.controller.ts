/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   consent.controller.ts                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Delete, Get, Param, Post, Put, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth, ApiSecurity } from '@nestjs/swagger';
import { AuthGuard, CurrentUser, UserContext } from '@mini-baas/common';
import { ConsentService } from './consent.service';
import { SetConsentDto, UpdateConsentDto } from '../dto/gdpr.dto';

@ApiTags('consent')
@Controller('consents')
@UseGuards(AuthGuard)
@ApiBearerAuth()
@ApiSecurity('apikey')
export class ConsentController {
  constructor(private readonly service: ConsentService) {}

  @Get()
  @ApiOperation({ summary: 'Get all my consents' })
  async list(@CurrentUser() user: UserContext) {
    return this.service.getUserConsents(user.id);
  }

  @Get(':type')
  @ApiOperation({ summary: 'Get a specific consent' })
  async get(
    @Param('type') type: string,
    @CurrentUser() user: UserContext,
  ) {
    return this.service.getUserConsent(user.id, type);
  }

  @Post()
  @ApiOperation({ summary: 'Set a consent (create or update)' })
  async set(
    @Body() dto: SetConsentDto,
    @CurrentUser() user: UserContext,
  ) {
    return this.service.setConsent(user.id, dto.consent_type, dto.consented);
  }

  @Put(':type')
  @ApiOperation({ summary: 'Update an existing consent' })
  async update(
    @Param('type') type: string,
    @Body() dto: UpdateConsentDto,
    @CurrentUser() user: UserContext,
  ) {
    return this.service.updateConsent(user.id, type, dto.consented);
  }

  @Delete('non-essential')
  @ApiOperation({ summary: 'Withdraw all non-essential consents' })
  async withdrawAll(@CurrentUser() user: UserContext) {
    return this.service.withdrawAllNonEssential(user.id);
  }
}
