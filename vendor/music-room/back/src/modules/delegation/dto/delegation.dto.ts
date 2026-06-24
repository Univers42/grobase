import { ApiProperty, ApiPropertyOptional, PartialType } from '@nestjs/swagger';
import {
  IsString,
  IsNotEmpty,
  IsOptional,
  IsEnum,
  IsMongoId,
  IsDateString,
  IsArray,
  ArrayMinSize,
} from 'class-validator';
import { DelegationPermission } from '../schemas';

// ─── Device DTOs ───

export class RegisterDeviceDto {
  @ApiProperty({ example: 'iPhone 15 Pro' })
  @IsString()
  @IsNotEmpty()
  name: string;

  @ApiProperty({ example: 'ios', enum: ['ios', 'android', 'web', 'iot'] })
  @IsString()
  @IsNotEmpty()
  platform: string;

  @ApiPropertyOptional({ example: 'ExponentPushToken[xxxxxx]' })
  @IsOptional()
  @IsString()
  deviceToken?: string;

  @ApiPropertyOptional({ example: 'iPhone 15,3' })
  @IsOptional()
  @IsString()
  model?: string;

  @ApiPropertyOptional({ example: '17.4' })
  @IsOptional()
  @IsString()
  osVersion?: string;
}

export class UpdateDeviceDto extends PartialType(RegisterDeviceDto) {}

// ─── Delegation DTOs ───

export class CreateDelegationDto {
  @ApiProperty({ description: 'User ID to delegate to' })
  @IsMongoId()
  delegate: string;

  @ApiPropertyOptional({ description: 'Target device ID' })
  @IsOptional()
  @IsMongoId()
  targetDevice?: string;

  @ApiProperty({
    description: 'Permissions to delegate',
    enum: DelegationPermission,
    isArray: true,
    example: [DelegationPermission.PLAYBACK_CONTROL, DelegationPermission.VOLUME_CONTROL],
  })
  @IsArray()
  @ArrayMinSize(1)
  @IsEnum(DelegationPermission, { each: true })
  permissions: DelegationPermission[];

  @ApiPropertyOptional({ description: 'Expiration date', example: '2025-12-31T23:59:59Z' })
  @IsOptional()
  @IsDateString()
  expiresAt?: string;
}

export class UpdateDelegationPermissionsDto {
  @ApiProperty({
    description: 'Updated permissions',
    enum: DelegationPermission,
    isArray: true,
  })
  @IsArray()
  @ArrayMinSize(1)
  @IsEnum(DelegationPermission, { each: true })
  permissions: DelegationPermission[];
}
