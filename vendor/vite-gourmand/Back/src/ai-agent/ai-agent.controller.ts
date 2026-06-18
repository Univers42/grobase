/**
 * AI Agent Controller
 * Endpoints for the AI menu customization assistant
 */
import { Controller, Get, Post, Delete, Body, Param } from '@nestjs/common';
import { ApiTags, ApiOperation } from '@nestjs/swagger';
import { AiAgentService } from './ai-agent.service';
import { ChatMessageDto } from './dto/ai-agent.dto';
import { Roles, CurrentUser, Public } from '../common';
import { JwtPayload } from '../common/types/request.types';

@ApiTags('ai-agent')
@Controller('ai-agent')
export class AiAgentController {
  constructor(private readonly aiAgentService: AiAgentService) {}

  @Get('status')
  @Public()
  @ApiOperation({
    summary: 'Check AI agent status (enabled / model / active conversations)',
  })
  getStatus() {
    return this.aiAgentService.getStatus();
  }

  @Post('chat')
  @Public()
  @ApiOperation({ summary: 'Send a message to the AI menu assistant (public)' })
  async chat(@Body() dto: ChatMessageDto, @CurrentUser() user?: JwtPayload) {
    return this.aiAgentService.chat(user?.sub ?? 0, dto);
  }

  @Get('conversations')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'List all active AI conversations' })
  listConversations() {
    return this.aiAgentService.listConversations();
  }

  @Get('conversations/:id')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get a specific conversation history' })
  getConversation(@Param('id') id: string) {
    return this.aiAgentService.getConversation(id);
  }

  @Delete('conversations/:id')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Delete a conversation' })
  deleteConversation(@Param('id') id: string) {
    this.aiAgentService.deleteConversation(id);
    return { message: 'Conversation deleted' };
  }
}
