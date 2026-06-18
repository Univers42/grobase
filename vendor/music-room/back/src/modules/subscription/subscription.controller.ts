import {
  Controller,
  Post,
  Get,
  Body,
} from '@nestjs/common';
import {
  ApiTags,
  ApiBearerAuth,
  ApiOperation,
} from '@nestjs/swagger';
import { SubscriptionService } from './subscription.service';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Public } from '../../common/decorators/public.decorator';
import { UpgradePlanDto, CancelSubscriptionDto, WebhookEventDto } from './dto';

@ApiTags('subscriptions')
@ApiBearerAuth()
@Controller('subscriptions')
export class SubscriptionController {
  constructor(private readonly subscriptionService: SubscriptionService) {}

  @Get('me')
  @ApiOperation({ summary: 'Get my subscription' })
  async getMySubscription(@CurrentUser() user: any) {
    return this.subscriptionService.getSubscription(user._id);
  }

  @Post('upgrade')
  @ApiOperation({ summary: 'Upgrade or change subscription plan' })
  async upgrade(
    @CurrentUser() user: any,
    @Body() dto: UpgradePlanDto,
  ) {
    return this.subscriptionService.upgradePlan(user._id, dto);
  }

  @Post('cancel')
  @ApiOperation({ summary: 'Cancel subscription' })
  async cancel(
    @CurrentUser() user: any,
    @Body() dto: CancelSubscriptionDto,
  ) {
    return this.subscriptionService.cancelSubscription(user._id, dto);
  }

  @Post('webhook')
  @Public()
  @ApiOperation({ summary: 'Payment provider webhook (public)' })
  async webhook(@Body() dto: WebhookEventDto) {
    await this.subscriptionService.handleWebhook(dto.type, dto.externalId, dto.data);
    return { received: true };
  }
}
