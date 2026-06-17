/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   chat.controller.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Delete, Get, Param, Post, Req, UseGuards } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth, ApiSecurity } from '@nestjs/swagger';
import { AuthGuard, OptionalAuthGuard, CurrentUser, UserContext } from '@mini-baas/common';
import { Request } from 'express';
import { ChatService } from './chat.service';
import { ChatMessageDto } from '../dto/ai.dto';

@ApiTags('chat')
@Controller('chat')
@ApiSecurity('apikey')
export class ChatController {
  constructor(private readonly service: ChatService) {}

  /**
   * Send a message. OptionalAuth — anonymous users can chat too.
   */
  @Post()
  @UseGuards(OptionalAuthGuard)
  @ApiOperation({ summary: 'Send a chat message (start or continue a conversation)' })
  async chat(@Body() dto: ChatMessageDto, @Req() req: Request) {
    return this.service.chat(dto.message, {
      conversationId: dto.conversationId,
      userId: req.user?.id,
      mode: dto.mode,
      context: dto.context,
    });
  }

  @Get('conversations')
  @UseGuards(AuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'List my conversations' })
  async list(@CurrentUser() user: UserContext) {
    return this.service.listConversations(user.id);
  }

  @Get('conversations/:id')
  @UseGuards(AuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Get a conversation with messages' })
  async get(
    @Param('id') id: string,
    @CurrentUser() user: UserContext,
  ) {
    return this.service.getConversation(id, user.id);
  }

  @Delete('conversations/:id')
  @UseGuards(AuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Delete a conversation' })
  async remove(
    @Param('id') id: string,
    @CurrentUser() user: UserContext,
  ) {
    return this.service.deleteConversation(id, user.id);
  }
}
