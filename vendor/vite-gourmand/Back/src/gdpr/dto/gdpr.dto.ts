/**
 * GDPR DTOs
 */
import { IsString, IsOptional, IsBoolean, IsEnum } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export enum ConsentType {
  MARKETING = 'marketing',
  ANALYTICS = 'analytics',
  THIRD_PARTY = 'third_party',
  ESSENTIAL = 'essential',
}

export enum DataDeletionStatus {
  PENDING = 'pending',
  IN_PROGRESS = 'in_progress',
  COMPLETED = 'completed',
  REJECTED = 'rejected',
}

export class CreateUserConsentDto {
  @ApiProperty({ enum: ConsentType })
  @IsEnum(ConsentType)
  consent_type!: ConsentType;

  @ApiProperty()
  @IsBoolean()
  consented!: boolean;
}

export class UpdateUserConsentDto {
  @ApiProperty()
  @IsBoolean()
  consented!: boolean;
}

export class CreateDataDeletionRequestDto {
  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  reason?: string;
}

export class ProcessDataDeletionRequestDto {
  @ApiProperty({
    enum: [
      DataDeletionStatus.IN_PROGRESS,
      DataDeletionStatus.COMPLETED,
      DataDeletionStatus.REJECTED,
    ],
  })
  @IsEnum(DataDeletionStatus)
  status!: DataDeletionStatus;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  admin_note?: string;
}
