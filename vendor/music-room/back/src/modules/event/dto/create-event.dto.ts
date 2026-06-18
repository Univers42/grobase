import { IsString, IsOptional, IsArray, IsEnum, IsNumber, Min, Max } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreateEventDto {
  @ApiProperty({ example: 'Summer Music Festival' })
  @IsString()
  name: string;

  @ApiPropertyOptional({ example: 'An amazing outdoor music event' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiProperty({
    example: { type: 'Point', coordinates: [2.3522, 48.8566] },
    description: 'GeoJSON Point with [longitude, latitude]',
  })
  location: {
    type: 'Point';
    coordinates: [number, number];
  };

  @ApiProperty({
    example: {
      start: '2025-06-01T18:00:00Z',
      end: '2025-06-01T23:00:00Z',
    },
  })
  timeWindow: {
    start: string;
    end: string;
  };

  @ApiPropertyOptional({ enum: ['public', 'private', 'friends'], default: 'public' })
  @IsOptional()
  @IsEnum(['public', 'private', 'friends'])
  visibility?: string;

  @ApiPropertyOptional({ example: ['rock', 'electronic'] })
  @IsOptional()
  @IsArray()
  @IsString({ each: true })
  tags?: string[];

  @ApiPropertyOptional({ example: 50 })
  @IsOptional()
  @IsNumber()
  @Min(1)
  @Max(100000)
  maxParticipants?: number;

  @ApiPropertyOptional({ example: 'default' })
  @IsOptional()
  @IsString()
  licenseType?: string;

  @ApiPropertyOptional({ example: 5000, description: 'License radius in meters' })
  @IsOptional()
  @IsNumber()
  @Min(100)
  @Max(50000)
  licenseRadius?: number;
}
