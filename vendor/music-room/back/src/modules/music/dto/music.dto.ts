import { IsString, IsNumber, IsOptional, Min, Max } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class SearchMusicDto {
  @ApiProperty({ example: 'bohemian rhapsody', description: 'Search query string' })
  @IsString()
  q: string;

  @ApiPropertyOptional({ example: 0, description: 'Result offset for pagination', default: 0 })
  @IsOptional()
  @IsNumber()
  @Min(0)
  index?: number;

  @ApiPropertyOptional({ example: 25, description: 'Number of results to return', default: 25 })
  @IsOptional()
  @IsNumber()
  @Min(1)
  @Max(100)
  limit?: number;
}

export class AddTrackDto {
  @ApiProperty({ example: '3135556', description: 'Deezer track ID' })
  @IsString()
  trackId: string;

  @ApiProperty({ example: 'Bohemian Rhapsody' })
  @IsString()
  title: string;

  @ApiProperty({ example: 'Queen' })
  @IsString()
  artist: string;

  @ApiPropertyOptional({ example: 'https://cdns-preview-d.dzcdn.net/...' })
  @IsOptional()
  @IsString()
  previewUrl?: string;

  @ApiPropertyOptional({ example: 'https://e-cdns-images.dzcdn.net/...' })
  @IsOptional()
  @IsString()
  albumCoverUrl?: string;

  @ApiPropertyOptional({ example: 354, description: 'Duration in seconds' })
  @IsOptional()
  @IsNumber()
  duration?: number;
}
