/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   admin.service.ts                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger } from '@nestjs/common';
import { MongoService } from '@mini-baas/database';
import { CreateIndexDto, UpdateSchemaDto } from './dto/admin.dto';

@Injectable()
export class AdminService {
  private readonly logger = new Logger(AdminService.name);

  constructor(private readonly mongo: MongoService) {}

  async listCollections() {
    const db = this.mongo.getDb();
    const collections = await db.listCollections().toArray();
    return collections.map((c) => ({ name: c.name, type: c.type }));
  }

  async getSchema(name: string) {
    const db = this.mongo.getDb();
    const info = await db.listCollections({ name }).toArray();
    if (!info.length) {
      return { name, validator: null };
    }
    const entry = info[0] as { options?: { validator?: unknown; validationLevel?: string; validationAction?: string } };
    return {
      name,
      validator: entry?.options?.validator ?? null,
      validationLevel: entry?.options?.validationLevel,
      validationAction: entry?.options?.validationAction,
    };
  }

  async updateSchema(name: string, dto: UpdateSchemaDto) {
    const db = this.mongo.getDb();
    await db.command({
      collMod: name,
      validator: dto.validator,
      validationLevel: dto.validationLevel ?? 'strict',
      validationAction: dto.validationAction ?? 'error',
    });
    this.logger.log(`Schema updated for collection: ${name}`);
    return { updated: true };
  }

  async dropCollection(name: string) {
    const db = this.mongo.getDb();
    await db.dropCollection(name);
    this.logger.warn(`Collection dropped: ${name}`);
    return { dropped: true };
  }

  async createIndex(name: string, dto: CreateIndexDto) {
    const db = this.mongo.getDb();
    const indexName = await db.collection(name).createIndex(dto.keys, dto.options ?? {});
    this.logger.log(`Index created on ${name}: ${indexName}`);
    return { index: indexName };
  }
}
