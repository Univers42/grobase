/**
 * Time Off DTOs
 */
import { IsString, IsOptional, IsDateString, IsEnum } from 'class-validator';
import { ApiProperty, ApiPropertyOptional, PartialType } from '@nestjs/swagger';

export enum TimeOffRequestType {
  VACATION = 'vacation',
  SICK_LEAVE = 'sick_leave',
  PERSONAL = 'personal',
  OTHER = 'other',
}

export enum TimeOffRequestStatus {
  PENDING = 'pending',
  APPROVED = 'approved',
  REJECTED = 'rejected',
  CANCELLED = 'cancelled',
}

export class CreateTimeOffRequestDto {
  @ApiProperty({ enum: TimeOffRequestType })
  @IsEnum(TimeOffRequestType)
  request_type!: TimeOffRequestType;

  @ApiProperty({ example: '2025-03-01' })
  @IsDateString()
  start_date!: string;

  @ApiProperty({ example: '2025-03-05' })
  @IsDateString()
  end_date!: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  reason?: string;
}

export class UpdateTimeOffRequestDto extends PartialType(
  CreateTimeOffRequestDto,
) {}

export class DecideTimeOffRequestDto {
  @ApiProperty({
    enum: [TimeOffRequestStatus.APPROVED, TimeOffRequestStatus.REJECTED],
  })
  @IsEnum(TimeOffRequestStatus)
  status!: TimeOffRequestStatus.APPROVED | TimeOffRequestStatus.REJECTED;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  decision_note?: string;
}
