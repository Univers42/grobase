/**
 * Diet DTOs
 */
import { IsString, IsOptional } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreateDietDto {
  @ApiProperty({ example: 'Vegan' })
  @IsString()
  name!: string;

  @ApiPropertyOptional({ example: 'Plant-based diet' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ example: 'https://example.com/vegan.png' })
  @IsOptional()
  @IsString()
  iconUrl?: string;
}

export class UpdateDietDto {
  @ApiPropertyOptional({ example: 'Vegan' })
  @IsOptional()
  @IsString()
  name?: string;

  @ApiPropertyOptional({ example: 'Plant-based diet' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ example: 'https://example.com/vegan.png' })
  @IsOptional()
  @IsString()
  iconUrl?: string;
}
