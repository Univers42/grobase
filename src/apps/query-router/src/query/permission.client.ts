import { ForbiddenException, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom } from 'rxjs';
import { QueryCacheService } from './query-cache.service';
import { QueryMetricsService } from './query.metrics';

export type ProductAction = 'read' | 'create' | 'update' | 'delete';

interface PermissionResponse {
  allowed?: boolean;
  permitted?: boolean;
  allow?: boolean;
  reason?: string;
}

@Injectable()
export class PermissionClient {
  private readonly permissionEngineUrl: string;
  private readonly timeoutMs: number;
  private readonly retryAttempts: number;

  constructor(
    private readonly config: ConfigService,
    private readonly http: HttpService,
    private readonly cache: QueryCacheService,
    private readonly metrics: QueryMetricsService,
  ) {
    this.permissionEngineUrl = this.config.get<string>(
      'PERMISSION_ENGINE_URL',
      'http://permission-engine:3050',
    );
    this.timeoutMs = this.config.get<number>('CONTROL_PLANE_TIMEOUT_MS', 2_000);
    this.retryAttempts = this.config.get<number>('CONTROL_PLANE_RETRY_ATTEMPTS', 2);
  }

  async assertAllowed(input: {
    userId: string;
    role?: string;
    resourceType: string;
    resourceName: string;
    action: ProductAction;
  }): Promise<void> {
    const cacheKey = this.cache.key(
      'permission',
      input.userId,
      input.resourceType,
      input.resourceName,
      input.action,
    );
    const cached = this.cache.get<boolean>(cacheKey);
    if (cached === true) {
      this.metrics.recordCache('permission', 'hit');
      return;
    }
    if (cached === false) {
      this.metrics.recordCache('permission', 'hit');
      this.metrics.recordPermissionDenied(input.resourceType, input.action);
      throw new ForbiddenException(
        `Permission denied for ${input.action} on ${input.resourceType}:${input.resourceName}`,
      );
    }

    this.metrics.recordCache('permission', 'miss');

    const inFlight = this.cache.getInFlight<PermissionResponse>(cacheKey);
    if (inFlight) {
      this.metrics.recordCoalesced('permission');
    }

    const data = await this.cache.coalesce(cacheKey, async () => {
      const url = `${this.permissionEngineUrl}/permissions/check`;
      return this.metrics.observe('permission_engine', 'control-plane', input.action, async () =>
        this.withRetry(async () => {
          const response = await firstValueFrom(
            this.http.post<PermissionResponse>(
              url,
              {
                resource_type: input.resourceType,
                resource_name: input.resourceName,
                action: input.action,
              },
              {
                timeout: this.timeoutMs,
                headers: {
                  'X-User-Id': input.userId,
                  'X-User-Role': input.role ?? 'authenticated',
                },
              },
            ),
          );
          return response.data;
        }),
      );
    });

    const allowed = data.allowed ?? data.permitted ?? data.allow ?? false;
    this.cache.set(cacheKey, allowed, this.cache.permissionTtlMs);
    this.metrics.recordCache('permission', 'set');

    if (!allowed) {
      this.metrics.recordPermissionDenied(input.resourceType, input.action);
      throw new ForbiddenException(
        data.reason ?? `Permission denied for ${input.action} on ${input.resourceType}:${input.resourceName}`,
      );
    }
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
