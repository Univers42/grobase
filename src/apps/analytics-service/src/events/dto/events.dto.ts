/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   events.dto.ts                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { IsNotEmpty, IsOptional, IsString, IsObject } from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class TrackEventDto {
  @ApiProperty({ example: 'page_view', description: 'Event type identifier' })
  @IsNotEmpty()
  @IsString()
  eventType!: string;

  @ApiPropertyOptional({ example: { page: '/home' }, description: 'Arbitrary event payload' })
  @IsOptional()
  @IsObject()
  data?: Record<string, unknown>;

  @ApiPropertyOptional({ description: 'Override user ID (internal use)' })
  @IsOptional()
  @IsString()
  userId?: string;
}

export class QueryEventsDto {
  @ApiProperty({ example: 'page_view' })
  @IsNotEmpty()
  @IsString()
  type!: string;

  @ApiPropertyOptional({ example: '2025-01-01T00:00:00Z', description: 'ISO date — only return events after this' })
  @IsOptional()
  @IsString()
  since?: string;

  @ApiPropertyOptional({ example: 100, description: 'Max results (default 100)' })
  @IsOptional()
  limit?: number;
}

export class EventStatsDto {
  @ApiPropertyOptional({ example: 'page_view', description: 'Filter by event type' })
  @IsOptional()
  @IsString()
  type?: string;

  @ApiPropertyOptional({ example: 7, description: 'Lookback window in days (default 7)' })
  @IsOptional()
  days?: number;
}
