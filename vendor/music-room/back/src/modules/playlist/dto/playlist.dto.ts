import {
  IsString,
  IsOptional,
  IsEnum,
  IsArray,
  IsNumber,
  Min,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { PlaylistVisibility, PlaylistLicenseType } from '../schemas/playlist.schema';

export class CreatePlaylistDto {
  @ApiProperty({ example: 'Chill Vibes' })
  @IsString()
  name: string;

  @ApiPropertyOptional({ example: 'A playlist for relaxing' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ enum: PlaylistVisibility, default: PlaylistVisibility.PUBLIC })
  @IsOptional()
  @IsEnum(PlaylistVisibility)
  visibility?: PlaylistVisibility;

  @ApiPropertyOptional({ enum: PlaylistLicenseType, default: PlaylistLicenseType.OPEN })
  @IsOptional()
  @IsEnum(PlaylistLicenseType)
  licenseType?: PlaylistLicenseType;

  @ApiPropertyOptional({ example: ['userId1', 'userId2'] })
  @IsOptional()
  @IsArray()
  @IsString({ each: true })
  invitedUsers?: string[];
}

export class UpdatePlaylistDto {
  @ApiPropertyOptional({ example: 'Updated Playlist Name' })
  @IsOptional()
  @IsString()
  name?: string;

  @ApiPropertyOptional({ example: 'Updated description' })
  @IsOptional()
  @IsString()
  description?: string;

  @ApiPropertyOptional({ enum: PlaylistVisibility })
  @IsOptional()
  @IsEnum(PlaylistVisibility)
  visibility?: PlaylistVisibility;

  @ApiPropertyOptional({ enum: PlaylistLicenseType })
  @IsOptional()
  @IsEnum(PlaylistLicenseType)
  licenseType?: PlaylistLicenseType;
}

export class AddTrackDto {
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

  @ApiProperty({ example: 0, description: 'Base version for optimistic concurrency' })
  @IsNumber()
  @Min(0)
  baseVersion: number;
}

export class ReorderTrackDto {
  @ApiProperty({ example: 123456, description: 'Deezer track ID to move' })
  @IsNumber()
  deezerTrackId: number;

  @ApiProperty({ example: 0, description: 'Current position (from)' })
  @IsNumber()
  @Min(0)
  fromPosition: number;

  @ApiProperty({ example: 3, description: 'Target position (to)' })
  @IsNumber()
  @Min(0)
  toPosition: number;

  @ApiProperty({ example: 0, description: 'Base version for optimistic concurrency' })
  @IsNumber()
  @Min(0)
  baseVersion: number;
}

export class RemoveTrackDto {
  @ApiProperty({ example: 0, description: 'Base version for optimistic concurrency' })
  @IsNumber()
  @Min(0)
  baseVersion: number;
}

export class InviteCollaboratorsDto {
  @ApiProperty({ example: ['userId1', 'userId2'] })
  @IsArray()
  @IsString({ each: true })
  userIds: string[];
}
