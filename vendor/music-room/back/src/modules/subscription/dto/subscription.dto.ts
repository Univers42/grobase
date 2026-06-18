import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  IsEnum,
  IsOptional,
  IsString,
  IsDateString,
} from 'class-validator';
import { SubscriptionPlan } from '../schemas';

export class UpgradePlanDto {
  @ApiProperty({
    description: 'Target plan',
    enum: SubscriptionPlan,
    example: SubscriptionPlan.PREMIUM,
  })
  @IsEnum(SubscriptionPlan)
  plan: SubscriptionPlan;

  @ApiPropertyOptional({
    description: 'Payment token from payment provider',
    example: 'tok_xxxx',
  })
  @IsOptional()
  @IsString()
  paymentToken?: string;
}

export class CancelSubscriptionDto {
  @ApiPropertyOptional({ description: 'Reason for cancellation' })
  @IsOptional()
  @IsString()
  reason?: string;

  @ApiPropertyOptional({
    description: 'Cancel at period end instead of immediately',
    example: true,
  })
  @IsOptional()
  cancelAtPeriodEnd?: boolean;
}

export class WebhookEventDto {
  @ApiProperty({ description: 'Webhook event type' })
  @IsString()
  type: string;

  @ApiProperty({ description: 'External subscription ID' })
  @IsString()
  externalId: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsDateString()
  periodEnd?: string;

  @ApiPropertyOptional({ type: Object })
  @IsOptional()
  data?: Record<string, any>;
}
