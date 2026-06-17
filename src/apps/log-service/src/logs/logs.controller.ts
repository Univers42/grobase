/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   logs.controller.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Body, Controller, Get, Post, Query } from '@nestjs/common';
import { ApiOperation, ApiSecurity, ApiTags } from '@nestjs/swagger';
import { LogBufferService } from './log-buffer.service';

interface IngestLogDto {
  level?: string;
  source?: string;
  message?: string;
  data?: Record<string, unknown>;
}

@ApiTags('logs')
@ApiSecurity('apikey')
@Controller('logs')
export class LogsController {
  constructor(private readonly buffer: LogBufferService) {}

  @Post('ingest')
  @ApiOperation({ summary: 'Ingest an application log entry' })
  ingest(@Body() body: IngestLogDto) {
    const entry = this.buffer.add({
      level: body.level ?? 'info',
      source: body.source ?? 'unknown',
      message: body.message ?? '',
      data: body.data,
    });
    return { accepted: true, entry };
  }

  @Get()
  @ApiOperation({ summary: 'List buffered log entries' })
  list(@Query('limit') limit?: string) {
    const parsedLimit = limit ? Number.parseInt(limit, 10) : 100;
    return this.buffer.list(Number.isFinite(parsedLimit) ? parsedLimit : 100);
  }
}