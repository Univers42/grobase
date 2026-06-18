/**
 * Menu DTOs
 * Validation for menu operations
 */
import {
  IsString,
  IsNumber,
  IsOptional,
  IsBoolean,
  IsDateString,
  Min,
} from 'class-validator';
import { Type } from 'class-transformer';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { PaginationDto } from '../../common';

export class CreateMenuDto {
  @ApiProperty({ example: 'Mediterranean Feast' })
  @IsString()
  title!: string;

  @ApiPropertyOptional({ example: 'A delicious Mediterranean menu' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiProperty({ example: 4 })
  @IsNumber()
  @Min(1)
  personMin!: number;

  @ApiProperty({ example: 25.99 })
  @IsNumber()
  @Min(0)
  pricePerPerson!: number;

  @ApiPropertyOptional({ example: 10 })
  @IsOptional()
  @IsNumber()
  remainingQty?: number;

  @ApiPropertyOptional({ example: 1 })
  @IsOptional()
  @IsNumber()
  dietId?: number;

  @ApiPropertyOptional({ example: 1 })
  @IsOptional()
  @IsNumber()
  themeId?: number;

  @ApiPropertyOptional({ example: false })
  @IsOptional()
  @IsBoolean()
  isSeasonal?: boolean;

  @ApiPropertyOptional({ example: '2024-06-01' })
  @IsOptional()
  @IsDateString()
  availableFrom?: string;

  @ApiPropertyOptional({ example: '2024-08-31' })
  @IsOptional()
  @IsDateString()
  availableUntil?: string;
}

export class UpdateMenuDto {
  @ApiPropertyOptional({ example: 'Mediterranean Feast' })
  @IsOptional()
  @IsString()
  title?: string;

  @ApiPropertyOptional({ example: 'A delicious Mediterranean menu' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ example: 4 })
  @IsOptional()
  @IsNumber()
  personMin?: number;

  @ApiPropertyOptional({ example: 25.99 })
  @IsOptional()
  @IsNumber()
  pricePerPerson?: number;

  @ApiPropertyOptional({ example: 10 })
  @IsOptional()
  @IsNumber()
  remainingQty?: number;

  @ApiPropertyOptional({ example: 1 })
  @IsOptional()
  @IsNumber()
  dietId?: number;

  @ApiPropertyOptional({ example: 1 })
  @IsOptional()
  @IsNumber()
  themeId?: number;
}

export class MenuFilterDto extends PaginationDto {
  @ApiPropertyOptional({ example: 1 })
  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  dietId?: number;

  @ApiPropertyOptional({ example: 1 })
  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  themeId?: number;

  @ApiPropertyOptional({ enum: ['published', 'draft', 'archived'] })
  @IsOptional()
  @IsString()
  status?: string;
}
