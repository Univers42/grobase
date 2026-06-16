/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   policy.dto.ts                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  ArrayMinSize,
  IsArray,
  IsEnum,
  IsInt,
  IsNotEmpty,
  IsObject,
  IsOptional,
  IsString,
  IsUUID,
  Max,
  Min,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreatePolicyDto {
  @ApiProperty({ example: '550e8400-…', description: 'Role UUID' })
  @IsUUID()
  role_id!: string;

  @ApiProperty({ example: 'table' })
  @IsString()
  @IsNotEmpty()
  resource_type!: string;

  @ApiProperty({ example: '*', description: '* for all, or specific name' })
  @IsString()
  @IsNotEmpty()
  resource_name!: string;

  @ApiProperty({ example: ['read', 'create'], type: [String] })
  @IsArray()
  @ArrayMinSize(1)
  @IsString({ each: true })
  actions!: string[];

  @ApiPropertyOptional({ example: { owner_only: true }, description: 'JSONB conditions (owner_only, ip_range, mfa_required, time_window)' })
  @IsOptional()
  @IsObject()
  conditions?: Record<string, unknown>;

  @ApiProperty({ enum: ['allow', 'deny'], default: 'allow' })
  @IsEnum(['allow', 'deny'])
  effect!: 'allow' | 'deny';

  @ApiPropertyOptional({ default: 0 })
  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(1000)
  priority?: number;
}
