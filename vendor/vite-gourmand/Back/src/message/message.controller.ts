/**
 * Message Controller
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
import { MessageService } from './message.service';
import { SafeParseIntPipe, CurrentUser } from '../common';
import { CreateMessageDto, ReplyMessageDto } from './dto/message.dto';
import { JwtPayload } from '../common/types/request.types';

@ApiTags('messages')
@Controller('messages')
@ApiBearerAuth()
export class MessageController {
  constructor(private readonly messageService: MessageService) {}

  @Get('inbox')
  @ApiOperation({ summary: 'Get inbox messages' })
  async getInbox(
    @CurrentUser() user: JwtPayload,
    @Query('unreadOnly') unreadOnly?: string,
    @Query('limit') limit?: string,
    @Query('offset') offset?: string,
  ) {
    return this.messageService.getInbox(user.sub, {
      unreadOnly: unreadOnly === 'true',
      limit: limit ? Number.parseInt(limit, 10) : undefined,
      offset: offset ? Number.parseInt(offset, 10) : undefined,
    });
  }

  @Get('sent')
  @ApiOperation({ summary: 'Get sent messages' })
  async getSent(
    @CurrentUser() user: JwtPayload,
    @Query('limit') limit?: string,
    @Query('offset') offset?: string,
  ) {
    return this.messageService.getSent(user.sub, {
      limit: limit ? Number.parseInt(limit, 10) : undefined,
      offset: offset ? Number.parseInt(offset, 10) : undefined,
    });
  }

  @Get('unread-count')
  @ApiOperation({ summary: 'Get unread message count' })
  async getUnreadCount(@CurrentUser() user: JwtPayload) {
    const count = await this.messageService.getUnreadCount(user.sub);
    return { count };
  }

  @Get(':id')
  @ApiOperation({ summary: 'Get message by ID' })
  async findOne(
    @Param('id', SafeParseIntPipe) id: number,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.messageService.findById(id, user.sub);
  }

  @Get(':id/thread')
  @ApiOperation({ summary: 'Get message thread' })
  async getThread(
    @Param('id', SafeParseIntPipe) id: number,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.messageService.getThread(id, user.sub);
  }

  @Post()
  @ApiOperation({ summary: 'Send a message' })
  async send(@Body() dto: CreateMessageDto, @CurrentUser() user: JwtPayload) {
    return this.messageService.send(user.sub, dto);
  }

  @Post(':id/reply')
  @ApiOperation({ summary: 'Reply to a message' })
  async reply(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: ReplyMessageDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.messageService.reply(user.sub, id, dto);
  }

  @Post(':id/read')
  @ApiOperation({ summary: 'Mark message as read' })
  async markAsRead(
    @Param('id', SafeParseIntPipe) id: number,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.messageService.markAsRead(id, user.sub);
  }

  @Delete(':id')
  @ApiOperation({ summary: 'Delete a message' })
  async delete(
    @Param('id', SafeParseIntPipe) id: number,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.messageService.delete(id, user.sub);
  }
}
