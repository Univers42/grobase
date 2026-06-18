/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema-ddl.dto.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/09 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/09 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsBoolean,
  IsEnum,
  IsOptional,
  IsString,
  ValidateNested,
} from 'class-validator';

/** The single supported DDL operations (snake_case, the Rust wire values). */
export const SCHEMA_DDL_OPS = [
  'add_column',
  'drop_column',
  'alter_column_type',
  'create_table',
  'drop_table',
] as const;
export type SchemaDdlOp = (typeof SCHEMA_DDL_OPS)[number];

/** Normalized column types creatable via DDL. `objectid`/`unknown` are
 *  describe-only (the data plane rejects them with 400). */
export const SCHEMA_DDL_COLUMN_TYPES = [
  'text',
  'integer',
  'float',
  'decimal',
  'boolean',
  'date',
  'datetime',
  'json',
  'uuid',
  'enum',
  'array',
] as const;
export type SchemaDdlColumnType = (typeof SCHEMA_DDL_COLUMN_TYPES)[number];

/**
 * One column definition (snake_case keys — this DTO IS the wire `ddl.column`
 * shape, minus the describe-only fields). `nullable`/`default`/`enum_values`
 * are optional here: for `add_column`/`create_table` the service defaults
 * them (nullable, no default); for `alter_column_type` the service composes
 * the FULL target definition by merging with the CURRENT column, so an
 * omitted attribute means "keep what the column has today".
 */
export class SchemaDdlColumnDto {
  @ApiProperty({ description: 'Column name' })
  @IsString()
  name!: string;

  @ApiProperty({ enum: SCHEMA_DDL_COLUMN_TYPES, description: 'Target normalized type' })
  @IsEnum(SCHEMA_DDL_COLUMN_TYPES)
  normalized_type!: SchemaDdlColumnType;

  @ApiPropertyOptional({ description: 'Whether NULLs are allowed (default true on create/add)' })
  @IsOptional()
  @IsBoolean()
  nullable?: boolean;

  @ApiPropertyOptional({
    description:
      "Raw engine default expression (`0`, `'pending'`, `now()`); `null` clears the default",
    nullable: true,
  })
  @IsOptional()
  @IsString()
  default?: string | null;

  @ApiPropertyOptional({
    description: 'Allowed values — required when normalized_type is `enum`',
    nullable: true,
    type: [String],
  })
  @IsOptional()
  @IsArray()
  @IsString({ each: true })
  enum_values?: string[] | null;
}

/**
 * Request body of `POST /query/v1/:dbId/schema/ddl` — ONE schema operation
 * per request (deliberate: MySQL DDL is auto-commit/non-transactional, so a
 * batch would fake atomicity). Destructive ops (`drop_column`, `drop_table`)
 * additionally require `confirm: true`.
 */
export class SchemaDdlRequestDto {
  @ApiProperty({ enum: SCHEMA_DDL_OPS, description: 'The DDL operation' })
  @IsEnum(SCHEMA_DDL_OPS)
  op!: SchemaDdlOp;

  @ApiProperty({ description: 'Target table / collection' })
  @IsString()
  table!: string;

  @ApiPropertyOptional({
    type: SchemaDdlColumnDto,
    description:
      'add_column: the new column; alter_column_type: the target definition ' +
      '(attributes omitted here are preserved from the current column)',
  })
  @IsOptional()
  @ValidateNested()
  @Type(() => SchemaDdlColumnDto)
  column?: SchemaDdlColumnDto;

  @ApiPropertyOptional({ description: 'drop_column: the column to drop' })
  @IsOptional()
  @IsString()
  column_name?: string;

  @ApiPropertyOptional({
    type: [SchemaDdlColumnDto],
    description: 'create_table: the table columns (owner_id is auto-appended if absent)',
  })
  @IsOptional()
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(100)
  @ValidateNested({ each: true })
  @Type(() => SchemaDdlColumnDto)
  columns?: SchemaDdlColumnDto[];

  @ApiPropertyOptional({
    type: [String],
    description: 'create_table: primary key column(s) — required for create_table',
  })
  @IsOptional()
  @IsArray()
  @ArrayMinSize(1)
  @IsString({ each: true })
  primary_key?: string[];

  @ApiPropertyOptional({
    description: 'Must be `true` for destructive ops (drop_column, drop_table)',
  })
  @IsOptional()
  @IsBoolean()
  confirm?: boolean;
}
