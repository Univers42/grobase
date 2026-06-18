/**
 * Theme DTOs
 */
import { IsString, IsOptional } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreateThemeDto {
  @ApiProperty({ example: 'Mediterranean' })
  @IsString()
  name!: string;

  @ApiPropertyOptional({ example: 'Flavors from the Mediterranean' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ example: 'https://example.com/mediterranean.png' })
  @IsOptional()
  @IsString()
  iconUrl?: string;
}

export class UpdateThemeDto {
  @ApiPropertyOptional({ example: 'Mediterranean' })
  @IsOptional()
  @IsString()
  name?: string;

  @ApiPropertyOptional({ example: 'Flavors from the Mediterranean' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ example: 'https://example.com/mediterranean.png' })
  @IsOptional()
  @IsString()
  iconUrl?: string;
}
