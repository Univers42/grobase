import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom } from 'rxjs';
import { QueryCacheService } from './query-cache.service';
import { QueryMetricsService } from './query.metrics';

export interface AdapterConnection {
  engine: string;
  connection_string: string;
}

@Injectable()
export class AdapterRegistryClient {
  private readonly registryUrl: string;
  private readonly serviceToken: string;
  private readonly timeoutMs: number;
  private readonly retryAttempts: number;

  constructor(
    private readonly config: ConfigService,
    private readonly http: HttpService,
    private readonly cache: QueryCacheService,
    private readonly metrics: QueryMetricsService,
  ) {
    this.registryUrl = this.config.getOrThrow<string>('ADAPTER_REGISTRY_URL');
    this.serviceToken = this.config.get<string>('ADAPTER_REGISTRY_SERVICE_TOKEN', '');
    this.timeoutMs = this.config.get<number>('CONTROL_PLANE_TIMEOUT_MS', 2_000);
    this.retryAttempts = this.config.get<number>('CONTROL_PLANE_RETRY_ATTEMPTS', 2);
  }

  async getConnection(dbId: string, userId: string): Promise<AdapterConnection> {
    const cacheKey = this.cache.key('adapter', userId, dbId);
    const cached = this.cache.get<AdapterConnection>(cacheKey);
    if (cached) {
      this.metrics.recordCache('adapter', 'hit');
      return cached;
    }

    this.metrics.recordCache('adapter', 'miss');

    const inFlight = this.cache.getInFlight<AdapterConnection>(cacheKey);
    if (inFlight) {
      this.metrics.recordCoalesced('adapter');
      return inFlight;
    }

    const data = await this.cache.coalesce(cacheKey, async () => {
      const url = `${this.registryUrl}/databases/${dbId}/connect`;
      return this.metrics.observe('adapter_registry', 'control-plane', 'connect', async () =>
        this.withRetry(async () => {
          const response = await firstValueFrom(
            this.http.get<AdapterConnection>(url, {
              timeout: this.timeoutMs,
              headers: {
                'X-Service-Token': this.serviceToken,
                'X-Tenant-Id': userId,
              },
            }),
          );
          return response.data;
        }),
      );
    });

    this.cache.set(cacheKey, data, this.cache.adapterTtlMs);
    this.metrics.recordCache('adapter', 'set');
    return data;
  }

  private async withRetry<T>(operation: () => Promise<T>): Promise<T> {
    let lastError: unknown;

    for (let attempt = 1; attempt <= Math.max(1, this.retryAttempts); attempt += 1) {
      try {
        return await operation();
      } catch (error) {
        lastError = error;
        if (attempt >= this.retryAttempts) break;
        await new Promise((resolve) => setTimeout(resolve, 100 * attempt));
      }
    }

    throw lastError;
  }
}
