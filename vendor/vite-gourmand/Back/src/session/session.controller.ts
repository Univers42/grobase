/**
 * Session Controller
 */
import {
  Controller,
  Get,
  Post,
  Delete,
  Param,
  Query,
  Headers,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { SessionService } from './session.service';
import { Roles, SafeParseIntPipe, CurrentUser } from '../common';
import { JwtPayload } from '../common/types/request.types';

@ApiTags('sessions')
@Controller('sessions')
@ApiBearerAuth()
export class SessionController {
  constructor(private readonly sessionService: SessionService) {}

  // User endpoints
  @Get()
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Get my sessions' })
  async getMySessions(
    @CurrentUser() user: JwtPayload,
    @Headers('authorization') auth?: string,
  ) {
    const currentToken = auth?.replace('Bearer ', '');
    return this.sessionService.getUserSessions(user.sub, currentToken);
  }

  @Get('active')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Get my active sessions' })
  async getMyActiveSessions(@CurrentUser() user: JwtPayload) {
    return this.sessionService.getActiveSessions(user.sub);
  }

  @Delete(':id')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Revoke specific session' })
  async revokeSession(
    @Param('id', SafeParseIntPipe) id: number,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.sessionService.revokeSession(id, user.sub);
  }

  @Post('revoke-all')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Revoke all other sessions' })
  async revokeAllSessions(
    @CurrentUser() user: JwtPayload,
    @Headers('authorization') auth?: string,
  ) {
    const currentToken = auth?.replace('Bearer ', '');
    return this.sessionService.revokeAllSessions(user.sub, currentToken);
  }

  // Admin endpoints
  @Get('admin/all')
  @Roles('admin')
  @ApiOperation({ summary: 'Get all sessions (admin)' })
  async getAllSessions(
    @Query('userId') userId?: string,
    @Query('active') active?: string,
  ) {
    return this.sessionService.getAllSessions({
      userId: userId ? Number.parseInt(userId, 10) : undefined,
      active: active === undefined ? undefined : active === 'true',
    });
  }

  @Get('admin/stats')
  @Roles('admin')
  @ApiOperation({ summary: 'Get session statistics (admin)' })
  async getSessionStats() {
    return this.sessionService.getSessionStats();
  }

  @Delete('admin/:id')
  @Roles('admin')
  @ApiOperation({ summary: 'Force revoke session (admin)' })
  async adminRevokeSession(@Param('id', SafeParseIntPipe) id: number) {
    return this.sessionService.adminRevokeSession(id);
  }

  @Post('admin/users/:userId/revoke-all')
  @Roles('admin')
  @ApiOperation({ summary: 'Force revoke all user sessions (admin)' })
  async adminRevokeAllUserSessions(
    @Param('userId', SafeParseIntPipe) userId: number,
  ) {
    return this.sessionService.adminRevokeAllUserSessions(userId);
  }

  @Post('admin/cleanup')
  @Roles('admin')
  @ApiOperation({ summary: 'Clean up expired sessions (admin)' })
  async cleanupExpiredSessions() {
    return this.sessionService.cleanupExpiredSessions();
  }
}
