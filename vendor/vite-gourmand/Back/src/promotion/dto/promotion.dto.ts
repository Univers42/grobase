/**
 * Promotion DTOs
 */
import {
  IsString,
  IsOptional,
  IsBoolean,
  IsInt,
  IsIn,
  IsDateString,
  MaxLength,
  Min,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional, PartialType } from '@nestjs/swagger';

const PROMOTION_TYPES = [
  'banner',
  'popup',
  'discount',
  'loyalty',
  'seasonal',
  'flash_sale',
] as const;

export class CreatePromotionDto {
  @ApiProperty({ example: 'Offre de Bienvenue -10%' })
  @IsString()
  @MaxLength(150)
  title!: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ example: '🎉 -10% sur votre 1ère commande' })
  @IsOptional()
  @IsString()
  @MaxLength(255)
  short_text?: string;

  @ApiProperty({ enum: PROMOTION_TYPES, default: 'banner' })
  @IsIn(PROMOTION_TYPES)
  type!: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  image_url?: string;

  @ApiPropertyOptional({ example: '/menu' })
  @IsOptional()
  @IsString()
  link_url?: string;

  @ApiPropertyOptional({ example: 'Voir nos menus' })
  @IsOptional()
  @IsString()
  @MaxLength(80)
  link_label?: string;

  @ApiPropertyOptional({ example: '-10%' })
  @IsOptional()
  @IsString()
  @MaxLength(40)
  badge_text?: string;

  @ApiPropertyOptional({ example: '#722F37' })
  @IsOptional()
  @IsString()
  @MaxLength(20)
  bg_color?: string;

  @ApiPropertyOptional({ example: '#FFFFFF' })
  @IsOptional()
  @IsString()
  @MaxLength(20)
  text_color?: string;

  @ApiPropertyOptional({ example: 1 })
  @IsOptional()
  @IsInt()
  discount_id?: number;

  @ApiPropertyOptional({ example: 100 })
  @IsOptional()
  @IsInt()
  @Min(0)
  priority?: number;

  @ApiPropertyOptional({ default: true })
  @IsOptional()
  @IsBoolean()
  is_active?: boolean;

  @ApiPropertyOptional({ default: true })
  @IsOptional()
  @IsBoolean()
  is_public?: boolean;

  @ApiProperty({ example: '2026-01-01T00:00:00Z' })
  @IsDateString()
  start_date!: string;

  @ApiPropertyOptional({ example: '2026-12-31T23:59:59Z' })
  @IsOptional()
  @IsDateString()
  end_date?: string;
}

export class UpdatePromotionDto extends PartialType(CreatePromotionDto) {}

export class AssignPromotionDto {
  @ApiProperty({ example: 8 })
  @IsInt()
  user_id!: number;

  @ApiProperty({ example: 1 })
  @IsInt()
  promotion_id!: number;
}
