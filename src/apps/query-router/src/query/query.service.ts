import { BadRequestException, Injectable } from '@nestjs/common';
import { PostgresqlEngine } from '../engines/postgresql.engine';
import { MongodbEngine } from '../engines/mongodb.engine';
import { ExecuteQueryDto } from './dto/query.dto';
import { AdapterRegistryClient } from './adapter-registry.client';
import { PermissionClient, ProductAction } from './permission.client';
import { QueryCacheService } from './query-cache.service';
import { QueryMetricsService } from './query.metrics';
import { AsyncEventService } from './async-event.service';

@Injectable()
export class QueryService {
  constructor(
    private readonly registry: AdapterRegistryClient,
    private readonly permissions: PermissionClient,
    private readonly cache: QueryCacheService,
    private readonly metrics: QueryMetricsService,
    private readonly events: AsyncEventService,
    private readonly pgEngine: PostgresqlEngine,
    private readonly mongoEngine: MongodbEngine,
  ) {}

  async executeQuery(dbId: string, table: string, userId: string, role: string, dto: ExecuteQueryDto) {
    const startedAt = Date.now();
    const { engine, connection_string } = await this.registry.getConnection(dbId, userId);
    const productAction = this.toProductAction(dto.action);
    const resourceType = engine === 'mongodb' ? 'collection' : 'table';

    try {
      await this.permissions.assertAllowed({
        userId,
        role,
        resourceType,
        resourceName: table,
        action: productAction,
      });

      const readCacheKey = this.readCacheKey(dbId, userId, engine, table, dto);
      if (productAction === 'read') {
        const cached = this.cache.get<unknown>(readCacheKey);
        if (cached) {
          this.metrics.recordCache('read', 'hit');
          this.metrics.recordRequest(engine, productAction, 'success');
          this.emitQueryEvent('query.cache_hit', engine, productAction, dbId, table, userId, startedAt);
          return cached;
        }

        this.metrics.recordCache('read', 'miss');
        const inFlight = this.cache.getInFlight<unknown>(readCacheKey);
        if (inFlight) {
          this.metrics.recordCoalesced('read');
          const coalesced = await inFlight;
          this.metrics.recordRequest(engine, productAction, 'success');
          this.emitQueryEvent('query.coalesced', engine, productAction, dbId, table, userId, startedAt);
          return coalesced;
        }

        const result = await this.cache.coalesce(readCacheKey, async () => {
          const executed = await this.executeAgainstEngine(engine, connection_string, table, productAction, dto, userId);
          this.cache.set(readCacheKey, executed, this.cache.readTtlMs);
          this.metrics.recordCache('read', 'set');
          return executed;
        });
        this.metrics.recordRequest(engine, productAction, 'success');
        this.emitQueryEvent('query.executed', engine, productAction, dbId, table, userId, startedAt);
        return result;
      }

      this.cache.deletePrefix(this.cache.key('read', userId, dbId, table));
      this.metrics.recordCache('read', 'invalidate');

      const result = await this.executeAgainstEngine(engine, connection_string, table, productAction, dto, userId);
      this.metrics.recordRequest(engine, productAction, 'success');
      this.emitQueryEvent('query.mutated', engine, productAction, dbId, table, userId, startedAt);
      return result;
    } catch (error) {
      this.metrics.recordRequest(engine, productAction, 'error');
      this.emitQueryEvent('query.failed', engine, productAction, dbId, table, userId, startedAt, error);
      throw error;
    }
  }

  async listTables(dbId: string, userId: string, role: string) {
    const startedAt = Date.now();
    const { engine, connection_string } = await this.registry.getConnection(dbId, userId);
    await this.permissions.assertAllowed({
      userId,
      role,
      resourceType: 'database',
      resourceName: dbId,
      action: 'read',
    });

    const cacheKey = this.cache.key('tables', userId, dbId, engine);
    const cached = this.cache.get<unknown>(cacheKey);
    if (cached) {
      this.metrics.recordCache('tables', 'hit');
      this.emitQueryEvent('tables.cache_hit', engine, 'read', dbId, 'database', userId, startedAt);
      return cached;
    }

    this.metrics.recordCache('tables', 'miss');

    const inFlight = this.cache.getInFlight<unknown>(cacheKey);
    if (inFlight) {
      this.metrics.recordCoalesced('tables');
      return inFlight;
    }

    const result = await this.cache.coalesce(cacheKey, async () => this.listTablesFromEngine(engine, connection_string));
    this.cache.set(cacheKey, result, this.cache.adapterTtlMs);
    this.metrics.recordCache('tables', 'set');
    this.emitQueryEvent('tables.listed', engine, 'read', dbId, 'database', userId, startedAt);
    return result;
  }

  private async executeAgainstEngine(
    engine: string,
    connectionString: string,
    table: string,
    productAction: ProductAction,
    dto: ExecuteQueryDto,
    userId: string,
  ): Promise<unknown> {
    return this.metrics.observe('adapter_execution', engine, productAction, async () => {
      if (engine === 'postgresql') {
        return this.pgEngine.execute(connectionString, table, this.toEngineAction(engine, productAction), {
          data: dto.data,
          filter: dto.filter,
          sort: dto.sort,
          limit: dto.limit,
          offset: dto.offset,
          userId,
        });
      }

      if (engine === 'mongodb') {
        const url = new URL(connectionString);
        const dbName = url.pathname.replace(/^\//, '') || 'test';
        return this.mongoEngine.execute(
          connectionString,
          dbName,
          table,
          this.toEngineAction(engine, productAction),
          {
            data: dto.data,
            filter: dto.filter,
            sort: dto.sort,
            limit: dto.limit,
            offset: dto.offset,
            userId,
          },
        );
      }

      throw new BadRequestException(`Unsupported engine: ${engine}`);
    });
  }

  private async listTablesFromEngine(engine: string, connectionString: string): Promise<unknown> {
    if (engine === 'postgresql') {
      const tables = await this.metrics.observe('adapter_list', engine, 'read', async () =>
        this.pgEngine.listTables(connectionString),
      );
      return { engine, tables };
    }

    if (engine === 'mongodb') {
      const url = new URL(connectionString);
      const dbName = url.pathname.replace(/^\//, '') || 'test';
      const collections = await this.metrics.observe('adapter_list', engine, 'read', async () =>
        this.mongoEngine.listCollections(connectionString, dbName),
      );
      return { engine, collections };
    }

    throw new BadRequestException(`Unsupported engine: ${engine}`);
  }

  private emitQueryEvent(
    type: string,
    engine: string,
    action: ProductAction,
    dbId: string,
    resource: string,
    userId: string,
    startedAt: number,
    error?: unknown,
  ): void {
    this.events.enqueue({
      type,
      level: error ? 'error' : 'info',
      message: error ? 'Query router request failed' : 'Query router request completed',
      metadata: {
        engine,
        action,
        database_id: dbId,
        resource,
        user_id: userId,
        latency_ms: Date.now() - startedAt,
        error: error instanceof Error ? error.message : undefined,
      },
    });
  }

  private toProductAction(action: string): ProductAction {
    switch (action) {
      case 'read':
      case 'select':
      case 'find':
        return 'read';
      case 'create':
      case 'insert':
      case 'insertOne':
        return 'create';
      case 'update':
      case 'updateMany':
        return 'update';
      case 'delete':
      case 'deleteMany':
        return 'delete';
      default:
        throw new BadRequestException(`Unsupported action: ${action}`);
    }
  }

  private toEngineAction(engine: string, action: ProductAction): string {
    if (engine === 'postgresql') {
      return {
        read: 'select',
        create: 'insert',
        update: 'update',
        delete: 'delete',
      }[action];
    }

    if (engine === 'mongodb') {
      return {
        read: 'find',
        create: 'insertOne',
        update: 'updateMany',
        delete: 'deleteMany',
      }[action];
    }

    throw new BadRequestException(`Unsupported engine: ${engine}`);
  }

  private readCacheKey(
    dbId: string,
    userId: string,
    engine: string,
    table: string,
    dto: ExecuteQueryDto,
  ): string {
    return this.cache.key(
      'read',
      userId,
      dbId,
      table,
      engine,
      JSON.stringify({
        filter: dto.filter ?? {},
        sort: dto.sort ?? {},
        limit: dto.limit ?? 100,
        offset: dto.offset ?? 0,
      }),
    );
  }
}
