/**
 * Loyalty DTOs
 */
import { IsString, IsOptional, IsNumber, IsEnum, Min } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export enum LoyaltyTransactionType {
  EARN = 'earn',
  REDEEM = 'redeem',
  EXPIRE = 'expire',
  BONUS = 'bonus',
}

export class CreateLoyaltyTransactionDto {
  @ApiProperty({ example: 100 })
  @IsNumber()
  points!: number;

  @ApiProperty({ enum: LoyaltyTransactionType, example: 'earn' })
  @IsEnum(LoyaltyTransactionType)
  type!: LoyaltyTransactionType;

  @ApiPropertyOptional({ example: 1 })
  @IsOptional()
  @IsNumber()
  orderId?: number;

  @ApiPropertyOptional({ example: 'Points earned from order #123' })
  @IsOptional()
  @IsString()
  description?: string;
}

export class RedeemPointsDto {
  @ApiProperty({ example: 50, description: 'Number of points to redeem' })
  @IsNumber()
  @Min(1)
  points!: number;

  @ApiPropertyOptional({ example: 1 })
  @IsOptional()
  @IsNumber()
  orderId?: number;
}

export class LoyaltyAccountResponseDto {
  id!: number;
  user_id!: number;
  total_earned!: number;
  total_spent!: number;
  balance!: number;
  last_activity_at!: Date | null;
}

export class LoyaltyTransactionResponseDto {
  id!: number;
  loyalty_account_id!: number;
  order_id!: number | null;
  points!: number;
  type!: string;
  description!: string | null;
  created_at!: Date;
}
