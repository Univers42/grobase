/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   collection.dto.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { BadRequestException } from '@nestjs/common';
import {
  IsInt,
  IsObject,
  IsOptional,
  IsString,
  Matches,
  Max,
  MaxLength,
  Min,
  validateSync,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { plainToInstance, Type } from 'class-transformer';

export class CreateDocumentDto {
  @ApiProperty({ description: 'Document data (owner_id and _id are injected server-side)' })
  @IsObject()
  data!: Record<string, unknown>;
}

export class PatchDocumentDto {
  @ApiProperty({ description: 'Fields to update via $set' })
  @IsObject()
  patch!: Record<string, unknown>;
}

const FIELDS_PATTERN = /^\w+(,\w+){0,31}$/;
const FIELDS_DOC = 'Comma-separated fields to return (id is always returned)';

export class PatchDocumentQueryDto {
  @ApiPropertyOptional({ example: 'title,rev', description: FIELDS_DOC })
  @IsOptional()
  @IsString()
  @Matches(FIELDS_PATTERN, { message: 'fields must be comma-separated field names' })
  fields?: string;

  @ApiPropertyOptional({
    example: 'rev',
    description: 'Update only while this field equals if_value',
  })
  @IsOptional()
  @IsString()
  @Matches(/^\w+$/, { message: 'if_field must be a field name' })
  if_field?: string;

  @ApiPropertyOptional({
    example: '3',
    description: 'Expected value of if_field (409 when it differs)',
  })
  @IsOptional()
  @IsString()
  @MaxLength(256)
  if_value?: string;
}

export class ListDocumentsQueryDto {
  @ApiPropertyOptional({ default: 20, minimum: 1, maximum: 100 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number = 20;

  @ApiPropertyOptional({ default: 0 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  offset?: number = 0;

  @ApiPropertyOptional({ example: 'created_at:desc', description: 'field:asc|desc' })
  @IsOptional()
  @IsString()
  @Matches(/^\w+:(asc|desc)$/i, { message: 'sort must be field:asc or field:desc' })
  sort?: string;

  @ApiPropertyOptional({ description: 'JSON filter object (owner_id/_id stripped)' })
  @IsOptional()
  @IsString()
  filter?: string;

  @ApiPropertyOptional({ example: 'title,updated_at', description: FIELDS_DOC })
  @IsOptional()
  @IsString()
  @Matches(FIELDS_PATTERN, { message: 'fields must be comma-separated field names' })
  fields?: string;
}

/**
 * The PATCH query keys, validated as PatchDocumentQueryDto. Read by hand rather than bound
 * with @Query(): the global pipe forbids unknown keys, and PATCH ignored every query key
 * before these three existed, so a client's cache-buster must keep working.
 */
export function readPatchQuery(raw: Record<string, unknown>): PatchDocumentQueryDto {
  const query = plainToInstance(PatchDocumentQueryDto, {
    fields: raw['fields'],
    if_field: raw['if_field'],
    if_value: raw['if_value'],
  });
  const errors = validateSync(query);
  if (errors.length > 0) {
    throw new BadRequestException(
      errors.flatMap((error) => Object.values(error.constraints ?? {})),
    );
  }
  return query;
}
