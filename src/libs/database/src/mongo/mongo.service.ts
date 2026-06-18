/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mongo.service.ts                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Db, MongoClient, MongoClientOptions } from 'mongodb';

/**
 * Managed MongoDB connection with configurable pool and health check.
 */
@Injectable()
export class MongoService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(MongoService.name);
  private client?: MongoClient;
  private db?: Db;

  constructor(private readonly config: ConfigService) {}

  async onModuleInit(): Promise<void> {
    const uri = this.config.get<string>('MONGO_URI', 'mongodb://mongo:27017');
    const dbName = this.config.get<string>('MONGO_DB_NAME', 'mini_baas');
    const maxPoolSize = this.config.get<number>('MONGO_MAX_POOL_SIZE', 10);
    const minPoolSize = this.config.get<number>('MONGO_MIN_POOL_SIZE', 2);
    // MONGO_OPTIONAL=1 makes mongo a soft dependency: a failed connect leaves
    // the service running with `isAvailable === false` instead of crashing the
    // app. Services that REQUIRE mongo (mongo-api, ai, analytics) don't set it
    // and keep today's fail-fast boot. Lean tiers run without a mongo container.
    const optional = /^(1|true|yes)$/i.test(String(this.config.get('MONGO_OPTIONAL', '')));

    const opts: MongoClientOptions = {
      maxPoolSize,
      minPoolSize,
      maxIdleTimeMS: 30_000,
      serverSelectionTimeoutMS: 5_000,
    };

    this.client = new MongoClient(uri, opts);
    try {
      await this.client.connect();
    } catch (error) {
      if (!optional) throw error;
      this.logger.warn(
        `MongoDB unavailable — degraded mode, projections disabled (MONGO_OPTIONAL): ${(error as Error).message}`,
      );
      await this.client.close().catch(() => undefined);
      this.client = undefined;
      return;
    }
    this.db = this.client.db(dbName);

    // Monitor errors
    this.client.on('commandFailed', (evt) => {
      this.logger.warn(`MongoDB command failed: ${evt.commandName} — ${evt.failure?.message}`);
    });

    this.logger.log(`MongoDB connected to ${dbName}`);
  }

  async onModuleDestroy(): Promise<void> {
    if (!this.client) return;
    await this.client.close();
    this.logger.log('MongoDB connection closed');
  }

  /** True when connected; false only in MONGO_OPTIONAL degraded mode. */
  get isAvailable(): boolean {
    return this.db !== undefined;
  }

  /** Get the database handle. */
  getDb(): Db {
    if (!this.db) throw new Error('MongoDB is unavailable (MONGO_OPTIONAL degraded mode)');
    return this.db;
  }

  /** Get the raw MongoClient. */
  getClient(): MongoClient {
    if (!this.client) throw new Error('MongoDB is unavailable (MONGO_OPTIONAL degraded mode)');
    return this.client;
  }

  /** Health check — ping the database. */
  async isHealthy(): Promise<boolean> {
    try {
      if (!this.db) return false;
      await this.db.command({ ping: 1 });
      return true;
    } catch {
      return false;
    }
  }
}
