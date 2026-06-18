/**
 * Dish DTOs
 */
import { IsString, IsOptional, IsIn } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

const COURSE_TYPES = ['entree', 'plat', 'dessert', 'boisson'] as const;

export class CreateDishDto {
  @ApiProperty({ example: 'Grilled Salmon' })
  @IsString()
  title!: string;

  @ApiPropertyOptional({ example: 'Fresh Atlantic salmon' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ example: 'https://example.com/salmon.jpg' })
  @IsOptional()
  @IsString()
  photoUrl?: string;

  @ApiPropertyOptional({ enum: COURSE_TYPES, default: 'plat' })
  @IsOptional()
  @IsString()
  @IsIn(COURSE_TYPES)
  courseType?: string;
}

export class UpdateDishDto {
  @ApiPropertyOptional({ example: 'Grilled Salmon' })
  @IsOptional()
  @IsString()
  title?: string;

  @ApiPropertyOptional({ example: 'Fresh Atlantic salmon' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ example: 'https://example.com/salmon.jpg' })
  @IsOptional()
  @IsString()
  photoUrl?: string;

  @ApiPropertyOptional({ enum: COURSE_TYPES })
  @IsOptional()
  @IsString()
  @IsIn(COURSE_TYPES)
  courseType?: string;
}
