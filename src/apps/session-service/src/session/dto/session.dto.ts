/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   session.dto.ts                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { IsString, IsOptional, IsNotEmpty } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class CreateSessionDto {
  @ApiProperty({ description: 'Opaque session token (e.g., JWT or random UUID)' })
  @IsNotEmpty()
  @IsString()
  token!: string;

  @ApiPropertyOptional({ description: 'Device or user-agent info' })
  @IsOptional()
  @IsString()
  deviceInfo?: string;

  @ApiPropertyOptional({ description: 'Client IP address' })
  @IsOptional()
  @IsString()
  ipAddress?: string;
}

export class ExtendSessionDto {
  @ApiPropertyOptional({ description: 'Days to extend (default: SESSION_TTL_DAYS env var or 7)' })
  @IsOptional()
  @IsString()
  days?: string;
}
