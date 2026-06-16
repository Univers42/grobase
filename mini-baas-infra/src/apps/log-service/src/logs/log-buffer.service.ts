/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   log-buffer.service.ts                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:12 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';

export interface BufferedLogEntry {
  level: string;
  source: string;
  message: string;
  data?: Record<string, unknown>;
  createdAt: string;
}

const MAX_BUFFER_SIZE = 1_000;

@Injectable()
export class LogBufferService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(LogBufferService.name);
  private readonly lokiUrl = process.env['LOG_SERVICE_LOKI_URL'] ?? 'http://loki:3100/loki/api/v1/push';
  private readonly batchSize = Number.parseInt(process.env['LOG_SERVICE_LOKI_BATCH_SIZE'] ?? '25', 10);
  private readonly flushMs = Number.parseInt(process.env['LOG_SERVICE_LOKI_FLUSH_MS'] ?? '1000', 10);
  private readonly entries: BufferedLogEntry[] = [];
  private readonly queue: BufferedLogEntry[] = [];
  private timer?: NodeJS.Timeout;

  onModuleInit(): void {
    this.timer = setInterval(() => void this.flush(), this.flushMs);
    this.timer.unref?.();
  }

  async onModuleDestroy(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    await this.flush();
  }

  add(entry: Omit<BufferedLogEntry, 'createdAt'>): BufferedLogEntry {
    const buffered = {
      ...entry,
      createdAt: new Date().toISOString(),
    };
    this.entries.push(buffered);
    if (this.entries.length > MAX_BUFFER_SIZE) {
      this.entries.shift();
    }
    this.queue.push(buffered);
    if (this.queue.length >= this.batchSize) void this.flush();
    return buffered;
  }

  list(limit = 100): BufferedLogEntry[] {
    return this.entries.slice(-Math.min(limit, MAX_BUFFER_SIZE));
  }

  getCount(): number {
    return this.entries.length;
  }

  private async flush(): Promise<void> {
    if (this.queue.length === 0) return;
    const batch = this.queue.splice(0, this.batchSize);
    try {
      const response = await fetch(this.lokiUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ streams: batch.map((entry) => this.toLokiStream(entry)) }),
      });
      if (!response.ok) throw new Error(`Loki push returned ${response.status}`);
    } catch (error) {
      this.queue.unshift(...batch);
      this.logger.warn(`Loki push failed: ${(error as Error).message}`);
    }
  }

  private toLokiStream(entry: BufferedLogEntry) {
    const timeNs = `${BigInt(new Date(entry.createdAt).getTime()) * 1_000_000n}`;
    return {
      stream: {
        service: entry.source,
        level: entry.level,
      },
      values: [
        [
          timeNs,
          JSON.stringify({
            service: entry.source,
            level: entry.level,
            message: entry.message,
            request_id: entry.data?.['request_id'],
            ...entry.data,
          }),
        ],
      ],
    };
  }
}