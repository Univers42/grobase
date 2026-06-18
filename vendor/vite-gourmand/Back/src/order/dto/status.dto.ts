/**
 * Status DTOs
 * Validation for status operations
 */
import { IsString, IsOptional, IsIn } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

const VALID_STATUSES = [
  'pending',
  'confirmed',
  'preparing',
  'ready',
  'delivering',
  'delivered',
  'cancelled',
] as const;

export class UpdateStatusDto {
  @ApiProperty({
    enum: VALID_STATUSES,
    example: 'confirmed',
  })
  @IsString()
  @IsIn(VALID_STATUSES)
  status!: string;

  @ApiPropertyOptional({ example: 'Order confirmed by manager' })
  @IsOptional()
  @IsString()
  notes?: string;
}
