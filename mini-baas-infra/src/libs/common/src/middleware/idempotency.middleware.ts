/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   idempotency.middleware.ts                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 15:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 22:30:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger, NestMiddleware, OnModuleDestroy } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import type { NextFunction, Request, Response } from 'express';
import Redis from 'ioredis';
import { createHash } from 'node:crypto';
import { Counter, register } from 'prom-client';

interface CachedIdempotencyResponse {
  fingerprint: string;
  responseHash: string;
  statusCode: number;
  contentType?: string;
  body: string;
  createdAt: string;
}

const MUTATING_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

type IdempotencyLabels = 'service' | 'result';

function idempotencyCounter(): Counter<IdempotencyLabels> {
  const existing = register.getSingleMetric('mini_baas_idempotency_requests_total');
  if (existing instanceof Counter) return existing;
  return new Counter<IdempotencyLabels>({
    name: 'mini_baas_idempotency_requests_total',
    help: 'Idempotency-Key decisions for mutating mini-BaaS requests.',
    labelNames: ['service', 'result'],
  });
}

@Injectable()
export class IdempotencyMiddleware implements NestMiddleware, OnModuleDestroy {
  private readonly logger = new Logger(IdempotencyMiddleware.name);
  private readonly redisUrl: string;
  private readonly ttlSeconds: number;
  private readonly serviceName = process.env['OTEL_SERVICE_NAME'] ?? process.env['APP_NAME'] ?? 'unknown-service';
  private readonly metrics = idempotencyCounter();
  private redisClient?: Redis;

  constructor(private readonly config: ConfigService) {
    this.redisUrl = this.config.get<string>('IDEMPOTENCY_REDIS_URL', 'redis://redis:6379');
    this.ttlSeconds = this.config.get<number>('IDEMPOTENCY_TTL_SECONDS', 86_400);
  }

  async use(req: Request, res: Response, next: NextFunction): Promise<void> {
    if (!MUTATING_METHODS.has(req.method.toUpperCase())) {
      this.count('bypass');
      next();
      return;
    }

    const idempotencyKey = this.header(req, 'idempotency-key');
    if (!idempotencyKey) {
      this.count('missing_key');
      next();
      return;
    }

    const actorId = req.identity?.tenantId ?? req.user?.tenantId ?? req.user?.id ?? 'anonymous';
    const cacheKey = this.cacheKey(actorId, idempotencyKey);
    const fingerprint = this.fingerprint(req);

    const cached = await this.read(cacheKey);
    if (cached) {
      if (cached.fingerprint !== fingerprint) {
        this.count('conflict');
        res.status(409).json({
          statusCode: 409,
          message: 'Idempotency-Key was already used with a different request payload',
        });
        return;
      }
      res.status(cached.statusCode);
      if (cached.contentType) res.setHeader('Content-Type', cached.contentType);
      res.setHeader('X-Idempotency-Replayed', 'true');
      this.count('replayed');
      res.send(cached.body);
      return;
    }

    let capturedBody = '';
    const originalSend = res.send.bind(res);
    type SendBody = Parameters<Response['send']>[0];
    res.send = ((body?: SendBody): Response => {
      capturedBody = this.serializeResponseBody(body);
      return originalSend(body);
    }) as Response['send'];

    res.on('finish', () => {
      if (!capturedBody || res.statusCode >= 500) return;
      const contentTypeHeader = res.getHeader('content-type');
      const contentType = Array.isArray(contentTypeHeader)
        ? contentTypeHeader.join('; ')
        : contentTypeHeader?.toString();
      const payload: CachedIdempotencyResponse = {
        fingerprint,
        responseHash: this.sha256(capturedBody),
        statusCode: res.statusCode,
        contentType,
        body: capturedBody,
        createdAt: new Date().toISOString(),
      };
      this.count('stored');
      void this.write(cacheKey, payload);
    });

    next();
  }

  async onModuleDestroy(): Promise<void> {
    if (this.redisClient) await this.redisClient.quit();
  }

  private header(req: Request, name: string): string | undefined {
    const value = req.headers[name];
    if (Array.isArray(value)) return value[0];
    return value;
  }

  private cacheKey(actorId: string, idempotencyKey: string): string {
    const keyMaterial = `${actorId}:${idempotencyKey}`;
    return `idempotency:v1:${this.sha256(keyMaterial)}`;
  }

  private fingerprint(req: Request): string {
    return this.sha256(
      this.stableStringify({
        method: req.method.toUpperCase(),
        path: req.originalUrl ?? req.url,
        body: req.body ?? null,
      }),
    );
  }

  private async client(): Promise<Redis> {
    this.redisClient ??= new Redis(this.redisUrl, {
      lazyConnect: true,
      enableOfflineQueue: false,
      maxRetriesPerRequest: 1,
    });
    if (this.redisClient.status !== 'ready') {
      await this.redisClient.connect().catch((error: Error) => {
        if (this.redisClient?.status !== 'ready') throw error;
      });
    }
    return this.redisClient;
  }

  private async read(cacheKey: string): Promise<CachedIdempotencyResponse | undefined> {
    try {
      const redis = await this.client();
      const raw = await redis.get(cacheKey);
      if (!raw) return undefined;
      return JSON.parse(raw) as CachedIdempotencyResponse;
    } catch (error) {
      this.count('read_error');
      this.logger.warn(`idempotency read failed: ${(error as Error).message}`);
      return undefined;
    }
  }

  private async write(cacheKey: string, payload: CachedIdempotencyResponse): Promise<void> {
    try {
      const redis = await this.client();
      await redis.set(cacheKey, JSON.stringify(payload), 'EX', this.ttlSeconds, 'NX');
    } catch (error) {
      this.count('write_error');
      this.logger.warn(`idempotency write failed: ${(error as Error).message}`);
    }
  }

  private count(result: string): void {
    this.metrics.inc({ service: this.serviceName, result });
  }

  private serializeResponseBody(body: unknown): string {
    if (body === undefined || body === null) return '';
    if (Buffer.isBuffer(body)) return new TextDecoder().decode(body);
    if (typeof body === 'string') return body;
    return JSON.stringify(body);
  }

  private stableStringify(value: unknown): string {
    if (value === null || typeof value !== 'object') return JSON.stringify(value);
    if (Array.isArray(value)) return `[${value.map((item) => this.stableStringify(item)).join(',')}]`;
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record)
      .sort((left, right) => left.localeCompare(right))
      .map((key) => `${JSON.stringify(key)}:${this.stableStringify(record[key])}`)
      .join(',')}}`;
  }

  private sha256(value: string): string {
    return createHash('sha256').update(value).digest('hex');
  }
}