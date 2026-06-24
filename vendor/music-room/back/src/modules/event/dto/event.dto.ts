import {
  IsString,
  IsOptional,
  IsEnum,
  IsArray,
  IsNumber,
  ValidateNested,
  IsDateString,
  Min,
} from 'class-validator';
import { Type } from 'class-transformer';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { EventVisibility, EventLicenseType } from '../schemas/event.schema';

class LocationDto {
  @ApiProperty({ example: [2.3522, 48.8566] })
  @IsArray()
  @IsNumber({}, { each: true })
  coordinates: number[];
}

class TimeWindowDto {
  @ApiPropertyOptional({ example: '2026-03-18T16:00:00Z' })
  @IsOptional()
  @IsDateString()
  start?: string;

  @ApiPropertyOptional({ example: '2026-03-18T18:00:00Z' })
  @IsOptional()
  @IsDateString()
  end?: string;
}

export class CreateEventDto {
  @ApiProperty({ example: 'Friday Night Party' })
  @IsString()
  name: string;

  @ApiPropertyOptional({ example: 'Come join us!' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ enum: EventVisibility, default: EventVisibility.PUBLIC })
  @IsOptional()
  @IsEnum(EventVisibility)
  visibility?: EventVisibility;

  @ApiPropertyOptional({ enum: EventLicenseType, default: EventLicenseType.OPEN })
  @IsOptional()
  @IsEnum(EventLicenseType)
  licenseType?: EventLicenseType;

  @ApiPropertyOptional({ type: LocationDto })
  @IsOptional()
  @ValidateNested()
  @Type(() => LocationDto)
  location?: LocationDto;

  @ApiPropertyOptional({ example: 500, description: 'Radius in meters' })
  @IsOptional()
  @IsNumber()
  @Min(1)
  geoRadius?: number;

  @ApiPropertyOptional({ type: TimeWindowDto })
  @IsOptional()
  @ValidateNested()
  @Type(() => TimeWindowDto)
  timeWindow?: TimeWindowDto;

  @ApiPropertyOptional({ example: ['userId1', 'userId2'] })
  @IsOptional()
  @IsArray()
  @IsString({ each: true })
  invitedUsers?: string[];
}

export class UpdateEventDto {
  @ApiPropertyOptional({ example: 'Updated Party Name' })
  @IsOptional()
  @IsString()
  name?: string;

  @ApiPropertyOptional({ example: 'Updated description' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ enum: EventVisibility })
  @IsOptional()
  @IsEnum(EventVisibility)
  visibility?: EventVisibility;

  @ApiPropertyOptional({ enum: EventLicenseType })
  @IsOptional()
  @IsEnum(EventLicenseType)
  licenseType?: EventLicenseType;

  @ApiPropertyOptional({ type: LocationDto })
  @IsOptional()
  @ValidateNested()
  @Type(() => LocationDto)
  location?: LocationDto;

  @ApiPropertyOptional({ example: 500 })
  @IsOptional()
  @IsNumber()
  @Min(1)
  geoRadius?: number;

  @ApiPropertyOptional({ type: TimeWindowDto })
  @IsOptional()
  @ValidateNested()
  @Type(() => TimeWindowDto)
  timeWindow?: TimeWindowDto;
}

export class SuggestTrackDto {
  @ApiProperty({ example: 123456, description: 'Deezer track ID' })
  @IsNumber()
  deezerTrackId: number;

  @ApiProperty({ example: 'Get Lucky' })
  @IsString()
  title: string;

  @ApiProperty({ example: 'Daft Punk' })
  @IsString()
  artist: string;

  @ApiPropertyOptional({ example: 'https://...' })
  @IsOptional()
  @IsString()
  albumCover?: string;

  @ApiPropertyOptional({ example: 'https://...' })
  @IsOptional()
  @IsString()
  previewUrl?: string;
}

export class InviteUsersDto {
  @ApiProperty({ example: ['userId1', 'userId2'] })
  @IsArray()
  @IsString({ each: true })
  userIds: string[];
}

export class VoteLocationDto {
  @ApiPropertyOptional({ example: 2.3522, description: 'Longitude (for geo-time license)' })
  @IsOptional()
  @IsNumber()
  longitude?: number;

  @ApiPropertyOptional({ example: 48.8566, description: 'Latitude (for geo-time license)' })
  @IsOptional()
  @IsNumber()
  latitude?: number;
}
