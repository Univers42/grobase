/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   events.service.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { MongoService } from '@mini-baas/database';
import { Collection, Document } from 'mongodb';

export interface AnalyticsEvent {
  eventType: string;
  userId?: string;
  timestamp: Date;
  data: Record<string, unknown>;
}

@Injectable()
export class EventsService implements OnModuleInit {
  private readonly logger = new Logger(EventsService.name);
  private collection!: Collection;

  constructor(
    private readonly mongo: MongoService,
    private readonly config: ConfigService,
  ) {}

  async onModuleInit(): Promise<void> {
    const db = this.mongo.getDb();
    this.collection = db.collection('events');

    // Ensure TTL index for automatic retention
    const retentionDays = this.config.get<number>('ANALYTICS_RETENTION_DAYS', 90);
    await this.collection.createIndex(
      { timestamp: 1 },
      { expireAfterSeconds: retentionDays * 86_400, name: 'ttl_retention' },
    ).catch((err) => {
      // Index may already exist with different TTL — log and continue
      this.logger.warn(`TTL index setup: ${(err as Error).message}`);
    });

    // Compound index for type + time queries
    await this.collection.createIndex(
      { eventType: 1, timestamp: -1 },
      { name: 'idx_type_time' },
    ).catch(() => { /* already exists */ });

    this.logger.log('Events collection indexes ensured');
  }

  /**
   * Insert a single analytics event.
   */
  async track(event: AnalyticsEvent): Promise<void> {
    await this.collection.insertOne({
      ...event,
      timestamp: new Date(),
    });
  }

  /**
   * Query events by type with optional time filter.
   */
  async getByType(
    eventType: string,
    opts: { since?: Date; limit?: number } = {},
  ): Promise<AnalyticsEvent[]> {
    const filter: Document = { eventType };
    if (opts.since) {
      filter['timestamp'] = { $gte: opts.since };
    }

    const docs = await this.collection
      .find(filter)
      .sort({ timestamp: -1 })
      .limit(opts.limit ?? 100)
      .toArray();

    return docs as unknown as AnalyticsEvent[];
  }

  /**
   * Aggregate event counts grouped by type over the last N days.
   * Optionally filter to a single event type.
   */
  async getStats(
    days = 7,
    eventType?: string,
  ): Promise<Record<string, number>> {
    const since = new Date();
    since.setDate(since.getDate() - days);

    const matchStage: Document = { timestamp: { $gte: since } };
    if (eventType) matchStage['eventType'] = eventType;

    const result = await this.collection
      .aggregate([
        { $match: matchStage },
        { $group: { _id: '$eventType', count: { $sum: 1 } } },
      ])
      .toArray();

    return result.reduce(
      (acc, r) => {
        acc[r['_id'] as string] = r['count'] as number;
        return acc;
      },
      {} as Record<string, number>,
    );
  }

  /**
   * List all distinct event types stored.
   */
  async getDistinctTypes(): Promise<string[]> {
    return this.collection.distinct('eventType');
  }

  /**
   * Health check — ping the underlying MongoDB connection.
   */
  async isHealthy(): Promise<boolean> {
    return this.mongo.isHealthy();
  }
}
