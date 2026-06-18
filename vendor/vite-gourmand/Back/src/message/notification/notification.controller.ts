/**
 * Notification Controller
 */
import {
  Controller,
  Get,
  Post,
  Delete,
  Body,
  Param,
  Query,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { NotificationService } from './notification.service';
import { Roles, SafeParseIntPipe, CurrentUser } from '../../common';
import {
  CreateNotificationDto,
  BulkNotificationDto,
} from './dto/notification.dto';
import { JwtPayload } from '../../common/types/request.types';

@ApiTags('notifications')
@Controller('notifications')
@ApiBearerAuth()
export class NotificationController {
  constructor(private readonly notificationService: NotificationService) {}

  @Get()
  @ApiOperation({ summary: 'Get my notifications' })
  async findAll(
    @CurrentUser() user: JwtPayload,
    @Query('unreadOnly') unreadOnly?: string,
    @Query('limit') limit?: string,
    @Query('offset') offset?: string,
  ) {
    return this.notificationService.findAll(user.sub, {
      unreadOnly: unreadOnly === 'true',
      limit: limit ? Number.parseInt(limit, 10) : undefined,
      offset: offset ? Number.parseInt(offset, 10) : undefined,
    });
  }

  @Get('unread-count')
  @ApiOperation({ summary: 'Get unread notification count' })
  async getUnreadCount(@CurrentUser() user: JwtPayload) {
    const count = await this.notificationService.getUnreadCount(user.sub);
    return { count };
  }

  @Get(':id')
  @ApiOperation({ summary: 'Get notification by ID' })
  async findOne(@Param('id', SafeParseIntPipe) id: number) {
    return this.notificationService.findById(id);
  }

  @Post(':id/read')
  @ApiOperation({ summary: 'Mark notification as read' })
  async markAsRead(
    @Param('id', SafeParseIntPipe) id: number,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.notificationService.markAsRead(id, user.sub);
  }

  @Post('read-all')
  @ApiOperation({ summary: 'Mark all notifications as read' })
  async markAllAsRead(@CurrentUser() user: JwtPayload) {
    return this.notificationService.markAllAsRead(user.sub);
  }

  @Delete(':id')
  @ApiOperation({ summary: 'Delete notification' })
  async delete(
    @Param('id', SafeParseIntPipe) id: number,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.notificationService.delete(id, user.sub);
  }

  @Delete()
  @ApiOperation({ summary: 'Delete all my notifications' })
  async deleteAll(@CurrentUser() user: JwtPayload) {
    return this.notificationService.deleteAll(user.sub);
  }

  // Admin endpoints
  @Post()
  @Roles('admin')
  @ApiOperation({ summary: 'Create notification for user (admin only)' })
  async create(@Body() dto: CreateNotificationDto) {
    return this.notificationService.create(dto);
  }

  @Post('bulk')
  @Roles('admin')
  @ApiOperation({ summary: 'Send bulk notifications (admin only)' })
  async createBulk(@Body() dto: BulkNotificationDto) {
    return this.notificationService.createBulk(dto);
  }
}
