/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema.dto.ts                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:40:54 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  ArrayMinSize,
  IsArray,
  IsBoolean,
  IsEnum,
  IsNotEmpty,
  IsObject,
  IsOptional,
  IsString,
  IsUUID,
  ValidateNested,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';

export class ColumnDefinition {
  @ApiProperty({ example: 'title' })
  @IsString()
  @IsNotEmpty()
  name!: string;

  @ApiProperty({ example: 'text', description: 'Postgres type or JSON Schema type' })
  @IsString()
  @IsNotEmpty()
  type!: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsBoolean()
  nullable?: boolean;

  @ApiPropertyOptional({ description: 'Default value expression' })
  @IsOptional()
  @IsString()
  default_value?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsBoolean()
  unique?: boolean;
}

export class CreateSchemaDto {
  @ApiProperty({ example: 'posts', description: 'Table/collection name' })
  @IsString()
  @IsNotEmpty()
  name!: string;

  @ApiProperty({ enum: ['postgresql', 'mongodb', 'mysql'] })
  @IsEnum(['postgresql', 'mongodb', 'mysql'])
  engine!: 'postgresql' | 'mongodb' | 'mysql';

  @ApiProperty({ description: 'Database ID from adapter-registry' })
  @IsUUID()
  database_id!: string;

  @ApiProperty({ type: [ColumnDefinition], minItems: 1 })
  @IsArray()
  @ArrayMinSize(1)
  @ValidateNested({ each: true })
  @Type(() => ColumnDefinition)
  columns!: ColumnDefinition[];

  @ApiPropertyOptional({ default: true, description: 'Enable RLS (Postgres only)' })
  @IsOptional()
  @IsBoolean()
  enable_rls?: boolean;

  @ApiPropertyOptional({ description: 'Additional engine-specific options' })
  @IsOptional()
  @IsObject()
  options?: Record<string, unknown>;
}
