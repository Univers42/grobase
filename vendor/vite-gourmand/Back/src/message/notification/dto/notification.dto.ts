/**
 * Notification DTOs
 */
import { IsString, IsOptional, IsNumber, MaxLength } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreateNotificationDto {
  @ApiProperty({ example: 1 })
  @IsNumber()
  userId!: number;

  @ApiProperty({ example: 'order_update' })
  @IsString()
  @MaxLength(50)
  type!: string;

  @ApiPropertyOptional({ example: 'Order Confirmed' })
  @IsOptional()
  @IsString()
  @MaxLength(255)
  title?: string;

  @ApiPropertyOptional({ example: 'Your order #123 has been confirmed' })
  @IsOptional()
  @IsString()
  body?: string;

  @ApiPropertyOptional({ example: '/orders/123' })
  @IsOptional()
  @IsString()
  @MaxLength(500)
  linkUrl?: string;
}

export class BulkNotificationDto {
  @ApiProperty({ example: [1, 2, 3] })
  @IsNumber({}, { each: true })
  userIds!: number[];

  @ApiProperty({ example: 'announcement' })
  @IsString()
  @MaxLength(50)
  type!: string;

  @ApiPropertyOptional({ example: 'New Menu Available' })
  @IsOptional()
  @IsString()
  @MaxLength(255)
  title?: string;

  @ApiPropertyOptional({ example: 'Check out our new summer menu!' })
  @IsOptional()
  @IsString()
  body?: string;

  @ApiPropertyOptional({ example: '/menus' })
  @IsOptional()
  @IsString()
  @MaxLength(500)
  linkUrl?: string;
}
