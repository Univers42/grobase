import { IsString, IsOptional, IsEnum, IsNumber, Min } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class VoteTrackDto {
  @ApiProperty({ example: '60d0fe4f5311236168a109ca', description: 'Event ID' })
  @IsString()
  eventId: string;

  @ApiProperty({ example: '3135556', description: 'Deezer track ID' })
  @IsString()
  trackId: string;

  @ApiProperty({ enum: ['up', 'down'], description: 'Vote direction' })
  @IsEnum(['up', 'down'])
  direction: 'up' | 'down';
}

export class JoinEventDto {
  @ApiProperty({ example: '60d0fe4f5311236168a109ca', description: 'Event ID to join' })
  @IsString()
  eventId: string;

  @ApiPropertyOptional({ example: 'secret123', description: 'Password for private events' })
  @IsOptional()
  @IsString()
  password?: string;
}

export class NearbyEventsDto {
  @ApiProperty({ example: 2.3522, description: 'Longitude' })
  @IsNumber()
  longitude: number;

  @ApiProperty({ example: 48.8566, description: 'Latitude' })
  @IsNumber()
  latitude: number;

  @ApiPropertyOptional({ example: 5000, description: 'Radius in meters', default: 5000 })
  @IsOptional()
  @IsNumber()
  @Min(100)
  radius?: number;
}
