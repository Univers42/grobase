/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   gdpr.dto.ts                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { IsString, IsOptional, IsBoolean, IsIn } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class SetConsentDto {
  @ApiProperty({ example: 'marketing', description: 'Consent type (free-form string — e.g. marketing, analytics, third_party)' })
  @IsString()
  consent_type!: string;

  @ApiProperty({ example: true })
  @IsBoolean()
  consented!: boolean;
}

export class UpdateConsentDto {
  @ApiProperty({ example: false })
  @IsBoolean()
  consented!: boolean;
}

export class CreateDeletionRequestDto {
  @ApiPropertyOptional({ example: 'I no longer use this service' })
  @IsOptional()
  @IsString()
  reason?: string;
}

export class ProcessDeletionRequestDto {
  @ApiProperty({
    enum: ['in_progress', 'completed', 'rejected'],
    example: 'completed',
  })
  @IsIn(['in_progress', 'completed', 'rejected'])
  status!: 'in_progress' | 'completed' | 'rejected';

  @ApiPropertyOptional({ example: 'Data has been anonymised' })
  @IsOptional()
  @IsString()
  admin_note?: string;
}
