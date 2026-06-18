/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.dto.ts                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 21:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  IsArray,
  IsBoolean,
  IsEnum,
  IsInt,
  IsObject,
  IsOptional,
  IsString,
  Max,
  Min,
  ValidateNested,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import type { AdapterOp } from '@mini-baas/database';

export const AGG_FUNCS = ['count', 'sum', 'avg', 'min', 'max'] as const;

/** One aggregate output column: `func(field) AS alias`. */
export class AggregateColumnDto {
  @ApiProperty({ enum: AGG_FUNCS })
  @IsEnum(AGG_FUNCS)
  func!: (typeof AGG_FUNCS)[number];

  @ApiPropertyOptional({ description: 'Column to aggregate; omit for count(*)' })
  @IsOptional()
  @IsString()
  field?: string;

  @ApiPropertyOptional({ description: '`func(DISTINCT field)` — requires `field`' })
  @IsOptional()
  @IsBoolean()
  distinct?: boolean;

  @ApiProperty({ description: 'Output column name' })
  @IsString()
  alias!: string;
}

/** A GROUP BY + aggregate request (`filter` scopes rows before grouping). */
export class AggregateDto {
  @ApiPropertyOptional({ type: [String], description: 'GROUP BY columns' })
  @IsOptional()
  @IsArray()
  @IsString({ each: true })
  groupBy?: string[];

  @ApiProperty({ type: [AggregateColumnDto], description: 'Aggregate output columns (≥1)' })
  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => AggregateColumnDto)
  aggregates!: AggregateColumnDto[];
}

/** Legacy actions accepted via the back-compat `action` field. */
export const LEGACY_ACTIONS = [
  'select',
  'insert',
  'update',
  'delete',
  'find',
  'insertOne',
  'updateMany',
  'deleteMany',
] as const;
export type LegacyAction = (typeof LEGACY_ACTIONS)[number];

/** Maps the deprecated `action` field onto the canonical `op` enum. */
const LEGACY_ACTION_MAP: Readonly<Record<LegacyAction, AdapterOp>> = Object.freeze({
  select: 'list',
  find: 'list',
  insert: 'insert',
  insertOne: 'insert',
  update: 'update',
  updateMany: 'update',
  delete: 'delete',
  deleteMany: 'delete',
});

export const ADAPTER_OPS = [
  'list',
  'get',
  'insert',
  'update',
  'delete',
  'upsert',
  'aggregate',
  'batch',
] as const;

/** Operations allowed inside a batch — everything except `batch` itself. */
export const BATCH_ITEM_OPS = [
  'list',
  'get',
  'insert',
  'update',
  'delete',
  'upsert',
  'aggregate',
] as const;

/** One batch sub-operation. `resource` defaults to the request's resource;
 *  nested batches are rejected (`op` excludes `batch`). */
export class BatchOperationDto {
  @ApiProperty({ enum: BATCH_ITEM_OPS })
  @IsEnum(BATCH_ITEM_OPS)
  op!: (typeof BATCH_ITEM_OPS)[number];

  @ApiPropertyOptional({ description: 'Target table/collection — defaults to the URL resource.' })
  @IsOptional()
  @IsString()
  resource?: string;

  @ApiPropertyOptional({ description: 'Row data for insert / update / upsert.' })
  @IsOptional()
  @IsObject()
  data?: Record<string, unknown>;

  @ApiPropertyOptional({ description: 'WHERE conditions (SQL) or query filter (MongoDB).' })
  @IsOptional()
  @IsObject()
  filter?: Record<string, unknown>;

  @ApiPropertyOptional({ description: 'Sort directive, e.g. `{ created_at: "desc" }`.' })
  @IsOptional()
  @IsObject()
  sort?: Record<string, 'asc' | 'desc'>;

  @ApiPropertyOptional({ minimum: 1, maximum: 500 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(500)
  limit?: number;

  @ApiPropertyOptional({ minimum: 0 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  offset?: number;
}

export class ExecuteQueryDto {
  @ApiPropertyOptional({
    enum: ADAPTER_OPS,
    description:
      'Canonical adapter operation. Use this in preference to the deprecated `action` field. One of `op` or `action` is required.',
  })
  @IsOptional()
  @IsEnum(ADAPTER_OPS)
  op?: AdapterOp;

  @ApiPropertyOptional({
    enum: LEGACY_ACTIONS,
    deprecated: true,
    description:
      'Deprecated alias kept for one minor version — prefer `op`. Routes legacy SQL/Mongo verbs onto the canonical operation set.',
  })
  @IsOptional()
  @IsString()
  @IsEnum(LEGACY_ACTIONS)
  action?: LegacyAction;

  @ApiPropertyOptional({ description: 'Row data for insert / update / upsert.' })
  @IsOptional()
  @IsObject()
  data?: Record<string, unknown>;

  @ApiPropertyOptional({ description: 'WHERE conditions (SQL) or query filter (MongoDB).' })
  @IsOptional()
  @IsObject()
  filter?: Record<string, unknown>;

  @ApiPropertyOptional({
    description: 'Sort directive, e.g. `{ created_at: "desc" }`.',
    example: { created_at: 'desc' },
  })
  @IsOptional()
  @IsObject()
  sort?: Record<string, 'asc' | 'desc'>;

  @ApiPropertyOptional({ default: 100, minimum: 1, maximum: 500 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(500)
  limit?: number = 100;

  @ApiPropertyOptional({ default: 0, minimum: 0 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  offset?: number = 0;

  @ApiPropertyOptional({
    description:
      'Idempotency key forwarded to adapters that support it (HTTP engine, M3 outbox). Same key + same payload = single side-effect.',
  })
  @IsOptional()
  @IsString()
  idempotencyKey?: string;

  @ApiPropertyOptional({
    type: AggregateDto,
    description:
      'Aggregation spec — required when `op: "aggregate"` (COUNT/SUM/AVG/MIN/MAX + GROUP BY).',
  })
  @IsOptional()
  @ValidateNested()
  @Type(() => AggregateDto)
  aggregate?: AggregateDto;

  @ApiPropertyOptional({
    type: [BatchOperationDto],
    description:
      'Sub-operations — required when `op: "batch"`. SQL engines run them in ONE transaction ' +
      '(atomic); mongo/redis run them ordered and stop at the first error. Size is capped by ' +
      "the engine's max_batch_size.",
  })
  @IsOptional()
  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => BatchOperationDto)
  operations?: BatchOperationDto[];

  /** Resolves the effective operation, preferring `op` over the legacy `action`. */
  resolveOp(): AdapterOp | undefined {
    if (this.op) return this.op;
    if (this.action) return LEGACY_ACTION_MAP[this.action];
    return undefined;
  }
}
