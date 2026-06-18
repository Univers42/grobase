/**
 * Image DTOs
 */
import { IsString, IsOptional, IsInt, IsUrl, IsBoolean } from 'class-validator';
import { ApiProperty, ApiPropertyOptional, PartialType } from '@nestjs/swagger';

// Menu Image DTOs
export class CreateMenuImageDto {
  @ApiProperty()
  @IsInt()
  menu_id!: number;

  @ApiProperty()
  @IsString()
  @IsUrl()
  image_url!: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  alt_text?: string;

  @ApiPropertyOptional({ default: false })
  @IsOptional()
  @IsBoolean()
  is_primary?: boolean;

  @ApiPropertyOptional()
  @IsOptional()
  @IsInt()
  display_order?: number;
}

export class UpdateMenuImageDto extends PartialType(CreateMenuImageDto) {}

// Review Image DTOs
export class CreateReviewImageDto {
  @ApiProperty()
  @IsInt()
  review_id!: number;

  @ApiProperty()
  @IsString()
  @IsUrl()
  image_url!: string;
}

export class UpdateReviewImageDto extends PartialType(CreateReviewImageDto) {}
