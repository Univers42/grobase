/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schemas.module.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:40:54 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Module, OnModuleInit } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { HttpModule } from '@nestjs/axios';
import { SchemasController } from './schemas.controller';
import { SchemasService } from './schemas.service';
import { PostgresSchemaEngine } from '../engines/postgres-schema.engine';
import { MongoSchemaEngine } from '../engines/mongo-schema.engine';
import { MysqlSchemaEngine } from '../engines/mysql-schema.engine';
import { PostgresService } from '@mini-baas/database';

@Module({
  imports: [ConfigModule, HttpModule],
  controllers: [SchemasController],
  providers: [SchemasService, PostgresSchemaEngine, MongoSchemaEngine, MysqlSchemaEngine],
})
export class SchemasModule implements OnModuleInit {
  constructor(private readonly pg: PostgresService) {}

  async onModuleInit(): Promise<void> {
    // Ensure schema_registry table exists
    await this.pg.adminQuery(`
      CREATE TABLE IF NOT EXISTS schema_registry (
        id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        database_id UUID NOT NULL,
        name        TEXT NOT NULL,
        engine      TEXT NOT NULL,
        columns     JSONB NOT NULL DEFAULT '[]'::jsonb,
        enable_rls  BOOLEAN DEFAULT true,
        created_by  UUID NOT NULL,
        created_at  TIMESTAMPTZ DEFAULT now(),
        updated_at  TIMESTAMPTZ DEFAULT now(),
        UNIQUE (database_id, name)
      )
    `);
    await this.pg.adminQuery(`
      CREATE TABLE IF NOT EXISTS public.engine_schema_migrations (
        id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        database_id UUID NOT NULL,
        engine      TEXT NOT NULL,
        version     INTEGER NOT NULL,
        name        TEXT NOT NULL,
        checksum    TEXT NOT NULL,
        metadata    JSONB NOT NULL DEFAULT '{}'::jsonb,
        applied_by  UUID NOT NULL,
        applied_at  TIMESTAMPTZ DEFAULT now(),
        UNIQUE (database_id, version)
      )
    `);
  }
}
