/**
 * Allergen DTOs
 */
import { IsString, IsOptional } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreateAllergenDto {
  @ApiProperty({ example: 'Gluten' })
  @IsString()
  name!: string;

  @ApiPropertyOptional({ example: 'https://example.com/gluten.png' })
  @IsOptional()
  @IsString()
  iconUrl?: string;
}

export class UpdateAllergenDto {
  @ApiPropertyOptional({ example: 'Gluten' })
  @IsOptional()
  @IsString()
  name?: string;

  @ApiPropertyOptional({ example: 'https://example.com/gluten.png' })
  @IsOptional()
  @IsString()
  iconUrl?: string;
}
