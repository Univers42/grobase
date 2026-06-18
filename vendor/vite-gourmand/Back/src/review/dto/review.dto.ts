/**
 * Review DTOs
 */
import {
  IsString,
  IsNumber,
  IsOptional,
  IsIn,
  Min,
  Max,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreateReviewDto {
  @ApiPropertyOptional({ example: 1 })
  @IsOptional()
  @IsNumber()
  orderId?: number;

  @ApiProperty({ example: 5, minimum: 1, maximum: 5 })
  @IsNumber()
  @Min(1)
  @Max(5)
  note!: number;

  @ApiProperty({ example: 'Excellent food and service!' })
  @IsString()
  description!: string;
}

export class ModerateReviewDto {
  @ApiProperty({ enum: ['approved', 'rejected'], example: 'approved' })
  @IsString()
  @IsIn(['approved', 'rejected'])
  status!: 'approved' | 'rejected';
}
