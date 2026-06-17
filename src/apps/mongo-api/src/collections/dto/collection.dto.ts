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

import { IsInt, IsObject, IsOptional, IsString, Matches, Max, Min } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';

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
}
