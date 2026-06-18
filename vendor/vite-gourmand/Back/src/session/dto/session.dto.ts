/**
 * Session DTOs
 */
import { IsString, IsOptional } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreateSessionDto {
  @ApiProperty()
  @IsString()
  token!: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  device_info?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  ip_address?: string;
}

export class SessionResponseDto {
  id!: number;
  user_id!: number;
  device_info?: string;
  ip_address?: string;
  created_at!: Date;
  expires_at!: Date;
  is_current?: boolean;
}
