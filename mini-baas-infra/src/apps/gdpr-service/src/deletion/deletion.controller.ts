/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   deletion.controller.ts                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Delete, Get, Param, Post, Query, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth, ApiSecurity } from '@nestjs/swagger';
import { AuthGuard, CurrentUser, Roles, RolesGuard, UserContext } from '@mini-baas/common';
import { DeletionService } from './deletion.service';
import { CreateDeletionRequestDto, ProcessDeletionRequestDto } from '../dto/gdpr.dto';

@ApiTags('deletion')
@Controller('deletion-requests')
@UseGuards(AuthGuard)
@ApiBearerAuth()
@ApiSecurity('apikey')
export class DeletionController {
  constructor(private readonly service: DeletionService) {}

  // ─── User endpoints ────────────────────────────────────────────

  @Post()
  @ApiOperation({ summary: 'Request data deletion (right to be forgotten)' })
  async create(
    @Body() dto: CreateDeletionRequestDto,
    @CurrentUser() user: UserContext,
  ) {
    return this.service.createRequest(user.id, dto.reason);
  }

  @Get('mine')
  @ApiOperation({ summary: 'Get my deletion request status' })
  async getMine(@CurrentUser() user: UserContext) {
    return this.service.getMyRequest(user.id);
  }

  @Delete('mine')
  @ApiOperation({ summary: 'Cancel my pending deletion request' })
  async cancelMine(@CurrentUser() user: UserContext) {
    return this.service.cancelRequest(user.id);
  }

  // ─── Admin endpoints ──────────────────────────────────────────

  @Get('admin')
  @UseGuards(RolesGuard)
  @Roles('service_role')
  @ApiOperation({ summary: 'List all deletion requests (admin)' })
  async listAll(@Query('status') status?: string) {
    return this.service.getAllRequests(status);
  }

  @Post('admin/:id/process')
  @UseGuards(RolesGuard)
  @Roles('service_role')
  @ApiOperation({ summary: 'Process a deletion request (admin)' })
  async process(
    @Param('id') id: string,
    @Body() dto: ProcessDeletionRequestDto,
    @CurrentUser() user: UserContext,
  ) {
    return this.service.processRequest(id, dto.status, user.id, dto.admin_note);
  }
}
