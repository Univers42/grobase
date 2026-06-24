import { IsString, IsOptional, IsArray, IsEnum, MinLength, MaxLength } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreatePlaylistDto {
  @ApiProperty({ example: 'Road Trip Vibes' })
  @IsString()
  @MinLength(1)
  @MaxLength(100)
  name: string;

  @ApiPropertyOptional({ example: 'Perfect playlist for long drives' })
  @IsOptional()
  @IsString()
  @MaxLength(500)
  description?: string;

  @ApiPropertyOptional({ enum: ['public', 'private', 'friends'], default: 'public' })
  @IsOptional()
  @IsEnum(['public', 'private', 'friends'])
  visibility?: string;

  @ApiPropertyOptional({ example: 'rock' })
  @IsOptional()
  @IsString()
  genre?: string;

  @ApiPropertyOptional({ example: ['road-trip', 'summer'] })
  @IsOptional()
  @IsArray()
  @IsString({ each: true })
  tags?: string[];

  @ApiPropertyOptional({ example: 'https://example.com/cover.jpg' })
  @IsOptional()
  @IsString()
  coverImageUrl?: string;
}
