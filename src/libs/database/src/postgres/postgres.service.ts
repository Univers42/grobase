/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   postgres.service.ts                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 22:30:37 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Pool, PoolClient, PoolConfig, QueryResultRow } from 'pg';

export interface TenantQueryContext {
  tenantId?: string;
  projectId?: string;
  appId?: string;
  userId: string;
  role?: string;
  scopes?: string[];
}

/**
 * Managed PostgreSQL connection pool with RLS tenant isolation.
 *
 * Provides two pools:
 * - adminPool (superuser, max 2): DDL, admin ops
 * - tenantPool (limited role, max 10): RLS-enforced tenant queries
 */
@Injectable()
export class PostgresService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(PostgresService.name);
  private adminPool!: Pool;
  private tenantPool!: Pool;

  constructor(private readonly config: ConfigService) {}

  async onModuleInit(): Promise<void> {
    const databaseUrl = this.config.getOrThrow<string>('DATABASE_URL');

    this.adminPool = new Pool({
      connectionString: databaseUrl,
      max: 2,
      idleTimeoutMillis: 30_000,
    });

    const tenantUser = this.config.get<string>(
      'ADAPTER_REGISTRY_DB_USER',
      'adapter_registry_role',
    );
    const tenantPass = this.config.get<string>(
      'ADAPTER_REGISTRY_DB_PASSWORD',
      'adapter_registry_pw',
    );

    const tenantConfig: PoolConfig = {
      connectionString: databaseUrl,
      max: 10,
      idleTimeoutMillis: 30_000,
    };

    // Override user/password if the limited role credentials are provided
    if (tenantUser && tenantPass) {
      const url = new URL(databaseUrl);
      url.username = tenantUser;
      url.password = tenantPass;
      tenantConfig.connectionString = url.toString();
    }

    this.tenantPool = new Pool(tenantConfig);

    // Verify connectivity
    const client = await this.adminPool.connect();
    try {
      await client.query('SELECT 1');
      this.logger.log('PostgreSQL admin pool connected');
    } finally {
      client.release();
    }
  }

  async onModuleDestroy(): Promise<void> {
    await Promise.all([this.adminPool.end(), this.tenantPool.end()]);
    this.logger.log('PostgreSQL pools closed');
  }

  /** Run a query on the admin (superuser) pool. */
  async adminQuery<T extends QueryResultRow = Record<string, unknown>>(
    text: string,
    params?: unknown[],
  ): Promise<T[]> {
    const result = await this.adminPool.query<T>(text, params);
    return result.rows;
  }

  /**
   * Run a query on the tenant pool with RLS context set.
   * Wraps execution in a transaction that sets tenant and user GUCs.
   */
  async tenantQuery<T extends QueryResultRow = Record<string, unknown>>(
    identityOrUserId: TenantQueryContext | string,
    text: string,
    params?: unknown[],
  ): Promise<T[]> {
    const identity = this.resolveTenantQueryContext(identityOrUserId);
    const client: PoolClient = await this.tenantPool.connect();
    try {
      await client.query('BEGIN');
      await client.query(
        `SELECT set_config('app.current_tenant_id', $1, true), set_config('app.current_user_id', $2, true), set_config('request.jwt.claims', $3, true)`,
        [
          identity.tenantId,
          identity.userId,
          JSON.stringify({
            sub: identity.userId,
            tenant_id: identity.tenantId,
            project_id: identity.projectId,
            app_id: identity.appId,
            role: identity.role,
            scopes: identity.scopes ?? [],
          }),
        ],
      );
      const result = await client.query<T>(text, params);
      await client.query('COMMIT');
      return result.rows;
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  }

  /** Get a raw client from the admin pool (caller must release). */
  async getAdminClient(): Promise<PoolClient> {
    return this.adminPool.connect();
  }

  private resolveTenantQueryContext(identityOrUserId: TenantQueryContext | string): Required<TenantQueryContext> {
    if (typeof identityOrUserId === 'string') {
      return {
        tenantId: identityOrUserId,
        projectId: identityOrUserId,
        appId: 'legacy',
        userId: identityOrUserId,
        role: 'authenticated',
        scopes: [],
      };
    }
    return {
      tenantId: identityOrUserId.tenantId ?? identityOrUserId.userId,
      projectId: identityOrUserId.projectId ?? identityOrUserId.tenantId ?? identityOrUserId.userId,
      appId: identityOrUserId.appId ?? 'legacy',
      userId: identityOrUserId.userId,
      role: identityOrUserId.role ?? 'authenticated',
      scopes: identityOrUserId.scopes ?? [],
    };
  }

  /** Check if the admin pool is healthy. */
  async isHealthy(): Promise<boolean> {
    try {
      await this.adminPool.query('SELECT 1');
      return true;
    } catch {
      return false;
    }
  }
}
