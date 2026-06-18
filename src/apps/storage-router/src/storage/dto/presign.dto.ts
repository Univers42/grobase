/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   presign.dto.ts                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { IsEnum, IsInt, IsOptional, IsString, Max, Min } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';

export class PresignDto {
  @ApiProperty({ enum: ['GET', 'PUT'], description: 'HTTP method for the presigned URL' })
  @IsEnum(['GET', 'PUT'])
  method!: 'GET' | 'PUT';

  @ApiPropertyOptional({ default: 3600, minimum: 60, maximum: 86400 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(60)
  @Max(86400)
  expiresIn?: number = 3600;

  @ApiPropertyOptional({ example: 'image/jpeg', description: 'Content-Type for PUT uploads' })
  @IsOptional()
  @IsString()
  contentType?: string;
}
