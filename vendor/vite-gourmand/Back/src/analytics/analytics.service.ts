/**
 * Analytics Service (MongoDB)
 */
import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { MongoClient, Db, Collection } from 'mongodb';

export interface AnalyticsEvent {
  eventType: string;
  userId?: string;
  timestamp: Date;
  data: Record<string, any>;
}

interface EventStatAggregate {
  _id: string;
  count: number;
}

@Injectable()
export class AnalyticsService implements OnModuleInit {
  private readonly logger = new Logger(AnalyticsService.name);
  private client: MongoClient | null = null;
  private db: Db | null = null;

  constructor(private readonly config: ConfigService) {}

  async onModuleInit() {
    await this.connect();
  }

  private async connect(): Promise<void> {
    if (this.isDisabled()) {
      return;
    }

    const uri = this.config.get<string>('MONGODB_URI');
    if (!uri) {
      this.logger.warn('MongoDB URI not configured, analytics disabled');
      return;
    }

    try {
      this.client = new MongoClient(uri);
      await this.client.connect();
      this.db = this.client.db('analytics');
      this.logger.log('Connected to MongoDB Analytics');
    } catch (error) {
      this.logger.error('Failed to connect to MongoDB', error);
    }
  }

  private isDisabled(): boolean {
    return (
      process.env.NODE_ENV === 'test' ||
      this.config.get<string>('ANALYTICS_ENABLED') === 'false' ||
      this.config.get<string>('ANALYTICS_DISABLED') === 'true'
    );
  }

  private getCollection<T extends object>(name: string): Collection<T> | null {
    return this.db?.collection<T>(name) || null;
  }

  async trackEvent(event: AnalyticsEvent): Promise<void> {
    const collection = this.getCollection<AnalyticsEvent>('events');
    if (!collection) return;

    try {
      await collection.insertOne({ ...event, timestamp: new Date() });
    } catch (error) {
      this.logger.error('Failed to track event', error);
    }
  }

  async getEventsByType(
    eventType: string,
    limit = 100,
  ): Promise<AnalyticsEvent[]> {
    const collection = this.getCollection<AnalyticsEvent>('events');
    if (!collection) return [];

    const docs = await collection
      .find({ eventType })
      .sort({ timestamp: -1 })
      .limit(limit)
      .toArray();

    return docs;
  }

  async getEventStats(days = 7): Promise<Record<string, number>> {
    const collection = this.getCollection('events');
    if (!collection) return {};

    const since = new Date();
    since.setDate(since.getDate() - days);

    const result = await collection
      .aggregate<EventStatAggregate>([
        { $match: { timestamp: { $gte: since } } },
        { $group: { _id: '$eventType', count: { $sum: 1 } } },
      ])
      .toArray();

    return result.reduce<Record<string, number>>((acc, r) => {
      acc[r._id] = r.count;
      return acc;
    }, {});
  }

  async disconnect(): Promise<void> {
    await this.client?.close();
  }
}
