/**
 * Newsletter Controller
 *
 * Public endpoints: subscribe, confirm, unsubscribe
 * Admin endpoints: list subscribers, send newsletter, history, stats
 */
import {
  Controller,
  Post,
  Get,
  Param,
  Body,
  Req,
  HttpCode,
  HttpStatus,
  ParseIntPipe,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { NewsletterService } from './newsletter.service';
import { SubscribeNewsletterDto } from './dto/newsletter.dto';
import { OptionalAuthRequest, Public, Roles } from '../common';

@ApiTags('Newsletter')
@Controller('newsletter')
export class NewsletterController {
  constructor(private readonly newsletterService: NewsletterService) {}

  /* ═══════════════════════════════════════════════════════════
     PUBLIC endpoints (no auth required)
     ═══════════════════════════════════════════════════════════ */

  @Public()
  @Post('subscribe')
  @HttpCode(HttpStatus.CREATED)
  @ApiOperation({ summary: 'Subscribe to newsletter (anonymous or logged-in)' })
  async subscribe(
    @Body() dto: SubscribeNewsletterDto,
    @Req() req: OptionalAuthRequest,
  ) {
    const userId = req.user?.sub;
    return this.newsletterService.subscribe(dto, userId);
  }

  @Public()
  @Get('confirm/:token')
  @ApiOperation({ summary: 'Confirm newsletter subscription via token' })
  async confirm(@Param('token') token: string) {
    return this.newsletterService.confirm(token);
  }

  @Public()
  @Get('unsubscribe/:token')
  @ApiOperation({ summary: 'Unsubscribe from newsletter via token' })
  async unsubscribe(@Param('token') token: string) {
    return this.newsletterService.unsubscribe(token);
  }

  /* ═══════════════════════════════════════════════════════════
     ADMIN endpoints
     ═══════════════════════════════════════════════════════════ */

  @Roles('admin', 'superadmin')
  @Get('subscribers')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'List all active newsletter subscribers (admin)' })
  async getSubscribers() {
    return this.newsletterService.getSubscribers();
  }

  @Roles('admin', 'superadmin')
  @Get('stats')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Get newsletter stats (admin)' })
  async getStats() {
    return this.newsletterService.getStats();
  }

  @Roles('admin', 'superadmin')
  @Post('send/:promotionId')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Send a promotion to all subscribers (admin)' })
  async sendNewsletter(
    @Param('promotionId', ParseIntPipe) promotionId: number,
    @Req() req: OptionalAuthRequest,
  ) {
    const sentBy = req.user?.sub;
    return this.newsletterService.sendPromotionNewsletter(promotionId, sentBy);
  }

  @Roles('admin', 'superadmin')
  @Get('history')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Get newsletter send history (admin)' })
  async getSendHistory() {
    return this.newsletterService.getSendHistory();
  }
}
