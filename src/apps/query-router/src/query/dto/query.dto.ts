import { IsEnum, IsInt, IsObject, IsOptional, Max, Min } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';

export class ExecuteQueryDto {
  @ApiProperty({
    enum: [
      'read',
      'create',
      'select',
      'insert',
      'update',
      'delete',
      'find',
      'insertOne',
      'updateMany',
      'deleteMany',
    ],
    description: 'Product action — read/create/update/delete. Legacy engine-specific actions are still accepted.',
  })
  @IsEnum([
    'read',
    'create',
    'select',
    'insert',
    'update',
    'delete',
    'find',
    'insertOne',
    'updateMany',
    'deleteMany',
  ])
  action!: string;

  @ApiPropertyOptional({ description: 'Row data for insert/update, or update payload for updateMany' })
  @IsOptional()
  @IsObject()
  data?: Record<string, unknown>;

  @ApiPropertyOptional({ description: 'WHERE conditions (SQL) or query filter (MongoDB)' })
  @IsOptional()
  @IsObject()
  filter?: Record<string, unknown>;

  @ApiPropertyOptional({ description: 'Sort specification, e.g. { "created_at": "desc" }' })
  @IsOptional()
  @IsObject()
  sort?: Record<string, string>;

  @ApiPropertyOptional({ default: 100, maximum: 100 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number = 100;

  @ApiPropertyOptional({ default: 0 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  offset?: number = 0;
}
