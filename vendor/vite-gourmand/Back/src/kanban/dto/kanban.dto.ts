/**
 * Kanban DTOs
 */
import {
  IsString,
  IsOptional,
  IsNumber,
  IsBoolean,
  MaxLength,
  Matches,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreateKanbanColumnDto {
  @ApiProperty({ example: 'In Progress' })
  @IsString()
  @MaxLength(100)
  name!: string;

  @ApiPropertyOptional({
    example: 'preparing',
    description: 'Mapped order status',
  })
  @IsOptional()
  @IsString()
  @MaxLength(30)
  mappedStatus?: string;

  @ApiPropertyOptional({ example: '#3498db' })
  @IsOptional()
  @IsString()
  @MaxLength(7)
  @Matches(/^#[0-9A-Fa-f]{6}$/, { message: 'Color must be a valid hex color' })
  color?: string;

  @ApiPropertyOptional({ example: 1 })
  @IsOptional()
  @IsNumber()
  position?: number;
}

export class UpdateKanbanColumnDto {
  @ApiPropertyOptional({ example: 'In Progress' })
  @IsOptional()
  @IsString()
  @MaxLength(100)
  name?: string;

  @ApiPropertyOptional({ example: 'preparing' })
  @IsOptional()
  @IsString()
  @MaxLength(30)
  mappedStatus?: string;

  @ApiPropertyOptional({ example: '#3498db' })
  @IsOptional()
  @IsString()
  @MaxLength(7)
  @Matches(/^#[0-9A-Fa-f]{6}$/, { message: 'Color must be a valid hex color' })
  color?: string;

  @ApiPropertyOptional({ example: 1 })
  @IsOptional()
  @IsNumber()
  position?: number;

  @ApiPropertyOptional({ example: true })
  @IsOptional()
  @IsBoolean()
  isActive?: boolean;
}

export class CreateOrderTagDto {
  @ApiProperty({ example: 'VIP' })
  @IsString()
  @MaxLength(50)
  label!: string;

  @ApiPropertyOptional({ example: '#e74c3c' })
  @IsOptional()
  @IsString()
  @MaxLength(7)
  @Matches(/^#[0-9A-Fa-f]{6}$/, { message: 'Color must be a valid hex color' })
  color?: string;
}

export class UpdateOrderTagDto {
  @ApiPropertyOptional({ example: 'VIP' })
  @IsOptional()
  @IsString()
  @MaxLength(50)
  label?: string;

  @ApiPropertyOptional({ example: '#e74c3c' })
  @IsOptional()
  @IsString()
  @MaxLength(7)
  @Matches(/^#[0-9A-Fa-f]{6}$/, { message: 'Color must be a valid hex color' })
  color?: string;
}
