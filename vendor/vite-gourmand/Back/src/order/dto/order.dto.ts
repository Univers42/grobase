/**
 * Order DTOs
 * Validation for order operations
 */
import {
  IsString,
  IsNumber,
  IsOptional,
  IsDateString,
  Min,
  Matches,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { PaginationDto } from '../../common';

export class CreateOrderDto {
  @ApiPropertyOptional({
    example: 1,
    description: 'ID of the menu being ordered',
  })
  @IsOptional()
  @IsNumber()
  @Min(1)
  menuId?: number;

  @ApiProperty({ example: '2024-06-15' })
  @IsDateString()
  deliveryDate!: string;

  @ApiProperty({ example: '12:00' })
  @IsString()
  @Matches(/^([01]\d|2[0-3]):([0-5]\d)$/, { message: 'Invalid time format' })
  deliveryHour!: string;

  @ApiProperty({ example: '123 Main Street, Paris' })
  @IsString()
  deliveryAddress!: string;

  @ApiProperty({ example: 4 })
  @IsNumber()
  @Min(1)
  personNumber!: number;

  @ApiProperty({ example: 100 })
  @IsNumber()
  @Min(0)
  menuPrice!: number;

  @ApiProperty({ example: 115 })
  @IsNumber()
  @Min(0)
  totalPrice!: number;

  @ApiPropertyOptional({ example: 'No nuts please' })
  @IsOptional()
  @IsString()
  specialInstructions?: string;
}

export class UpdateOrderDto {
  @ApiPropertyOptional({ example: '123 Main Street, Paris' })
  @IsOptional()
  @IsString()
  deliveryAddress?: string;

  @ApiPropertyOptional({ example: '12:00' })
  @IsOptional()
  @IsString()
  deliveryHour?: string;

  @ApiPropertyOptional({ example: 'No nuts please' })
  @IsOptional()
  @IsString()
  specialInstructions?: string;
}

export class OrderFilterDto extends PaginationDto {
  @ApiPropertyOptional({
    enum: [
      'pending',
      'confirmed',
      'preparing',
      'ready',
      'delivering',
      'delivered',
      'cancelled',
    ],
  })
  @IsOptional()
  @IsString()
  status?: string;

  @ApiPropertyOptional({ example: '2024-06-01' })
  @IsOptional()
  @IsDateString()
  fromDate?: string;

  @ApiPropertyOptional({ example: '2024-06-30' })
  @IsOptional()
  @IsDateString()
  toDate?: string;
}
