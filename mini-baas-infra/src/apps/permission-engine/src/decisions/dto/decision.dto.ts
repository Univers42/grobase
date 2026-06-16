import { Type } from 'class-transformer';
import { IsIn, IsNotEmpty, IsObject, IsOptional, IsString, ValidateNested } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

const DECISION_OPS = ['list', 'get', 'insert', 'update', 'delete', 'upsert'] as const;

export class DecisionUserDto {
  @ApiProperty({ example: '00000000-0000-4000-8000-000000000009' })
  @IsString()
  @IsNotEmpty()
  id!: string;

  @ApiPropertyOptional({ example: 'authenticated' })
  @IsOptional()
  @IsString()
  role?: string;

  @ApiPropertyOptional({ example: 'user@example.com' })
  @IsOptional()
  @IsString()
  email?: string;
}

export class DecidePermissionDto {
  @ApiProperty({ type: DecisionUserDto })
  @ValidateNested()
  @Type(() => DecisionUserDto)
  user!: DecisionUserDto;

  @ApiPropertyOptional({ example: '00000000-0000-4000-8000-000000000002' })
  @IsOptional()
  @IsString()
  tenant_id?: string;

  @ApiPropertyOptional({ example: '00000000-0000-4000-8000-000000000002' })
  @IsOptional()
  @IsString()
  project_id?: string;

  @ApiPropertyOptional({ example: 'verify' })
  @IsOptional()
  @IsString()
  app_id?: string;

  @ApiProperty({ example: 'postgresql' })
  @IsString()
  @IsNotEmpty()
  resource_type!: string;

  @ApiProperty({ example: 'crm_contacts' })
  @IsString()
  @IsNotEmpty()
  resource_name!: string;

  @ApiProperty({ enum: DECISION_OPS, example: 'insert' })
  @IsIn(DECISION_OPS)
  op!: (typeof DECISION_OPS)[number];

  /**
   * Optional per-instance subject — the specific row/object id the caller is
   * acting on. Folded into the PDP attrs as `resource_id` so a policy whose
   * conditions carry `resource_id` / `resource_id_in` can decide per-instance
   * (B3). Absent ⇒ table-level decision only (today's behavior).
   */
  @ApiPropertyOptional({ example: 'row-123' })
  @IsOptional()
  @IsString()
  resource_id?: string;

  @ApiPropertyOptional({ example: { ip: '127.0.0.1', request_id: 'req-1', aal: 'aal2' } })
  @IsOptional()
  @IsObject()
  attributes?: Record<string, unknown>;
}