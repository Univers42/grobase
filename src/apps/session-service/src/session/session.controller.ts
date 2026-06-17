/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   session.controller.ts                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Post,
  Headers,
  UseGuards,
  Query,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth, ApiSecurity } from '@nestjs/swagger';
import { AuthGuard, CurrentUser, Roles, RolesGuard, UserContext } from '@mini-baas/common';
import { SessionService } from './session.service';
import { CreateSessionDto, ExtendSessionDto } from './dto/session.dto';

@ApiTags('sessions')
@Controller('sessions')
@ApiSecurity('apikey')
export class SessionController {
  constructor(private readonly service: SessionService) {}

  /* ─────── User endpoints ─────── */

  @Post()
  @UseGuards(AuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Create a new session for the current user' })
  async create(
    @CurrentUser() user: UserContext,
    @Body() dto: CreateSessionDto,
  ) {
    return this.service.create(user.id, dto.token, dto.deviceInfo, dto.ipAddress);
  }

  @Get('mine')
  @UseGuards(AuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'List my sessions' })
  async mySessions(
    @CurrentUser() user: UserContext,
    @Headers('authorization') auth?: string,
  ) {
    const currentToken = auth?.replace('Bearer ', '');
    return this.service.getUserSessions(user.id, currentToken);
  }

  @Post('validate')
  @ApiOperation({ summary: 'Validate a session token' })
  async validate(@Body('token') token: string) {
    return this.service.validate(token);
  }

  @Post('extend')
  @UseGuards(AuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Extend current session expiry' })
  async extend(
    @Headers('authorization') auth: string,
    @Body() dto: ExtendSessionDto,
  ) {
    const token = auth?.replace('Bearer ', '');
    return this.service.extend(token, dto.days ? Number.parseInt(dto.days, 10) : undefined);
  }

  @Delete(':id')
  @UseGuards(AuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Revoke one of my sessions' })
  async revoke(
    @Param('id') id: string,
    @CurrentUser() user: UserContext,
  ) {
    return this.service.revoke(id, user.id);
  }

  @Post('revoke-all')
  @UseGuards(AuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Revoke all my other sessions (keep current)' })
  async revokeAll(
    @CurrentUser() user: UserContext,
    @Headers('authorization') auth?: string,
  ) {
    const currentToken = auth?.replace('Bearer ', '');
    return this.service.revokeAll(user.id, currentToken);
  }

  /* ─────── Admin endpoints ─────── */

  @Get('admin/all')
  @UseGuards(AuthGuard, RolesGuard)
  @Roles('service_role')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'List all active sessions (admin)' })
  async adminList(@Query('userId') userId?: string) {
    return this.service.getActiveSessions(userId);
  }

  @Get('admin/stats')
  @UseGuards(AuthGuard, RolesGuard)
  @Roles('service_role')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Session statistics (admin)' })
  async adminStats() {
    return this.service.getStats();
  }

  @Delete('admin/:id')
  @UseGuards(AuthGuard, RolesGuard)
  @Roles('service_role')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Force-revoke any session (admin)' })
  async adminForceRevoke(@Param('id') id: string) {
    return this.service.adminForceRevoke(id);
  }

  @Post('admin/users/:userId/revoke-all')
  @UseGuards(AuthGuard, RolesGuard)
  @Roles('service_role')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Force-revoke all sessions for a user (admin)' })
  async adminForceRevokeAll(@Param('userId') userId: string) {
    return this.service.adminForceRevokeAll(userId);
  }

  @Post('admin/cleanup')
  @UseGuards(AuthGuard, RolesGuard)
  @Roles('service_role')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Delete expired sessions (admin)' })
  async adminCleanup() {
    return this.service.cleanupExpired();
  }
}
