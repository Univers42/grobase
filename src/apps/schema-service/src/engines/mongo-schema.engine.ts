/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mongo-schema.engine.ts                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { MongoClient } from 'mongodb';
import { ColumnDefinition } from '../schemas/dto/schema.dto';

const COLLECTION_REGEX = /^[\w-]{1,64}$/;

const TYPE_MAP: Record<string, string> = {
  text: 'string',
  varchar: 'string',
  string: 'string',
  integer: 'int',
  int: 'int',
  number: 'double',
  boolean: 'bool',
  bool: 'bool',
  date: 'date',
  timestamp: 'date',
  uuid: 'string',
  object: 'object',
  array: 'array',
};

@Injectable()
export class MongoSchemaEngine {
  private readonly logger = new Logger(MongoSchemaEngine.name);

  async createCollection(
    connectionString: string,
    dbName: string,
    collectionName: string,
    columns: ColumnDefinition[],
  ): Promise<{ created: boolean }> {
    if (!COLLECTION_REGEX.test(collectionName)) {
      throw new BadRequestException(`Invalid collection name: ${collectionName}`);
    }

    const properties: Record<string, unknown> = {
      owner_id: { bsonType: 'string' },
      created_at: { bsonType: 'date' },
      updated_at: { bsonType: 'date' },
    };

    const required = ['owner_id', 'created_at', 'updated_at'];

    for (const col of columns) {
      const bsonType = TYPE_MAP[col.type.toLowerCase()];
      if (!bsonType) {
        throw new BadRequestException(`Unsupported type for MongoDB: ${col.type}`);
      }
      properties[col.name] = { bsonType };
      if (!col.nullable) {
        required.push(col.name);
      }
    }

    const validator = {
      $jsonSchema: {
        bsonType: 'object',
        required,
        properties,
      },
    };

    const client = new MongoClient(connectionString, {
      maxPoolSize: 5,
      serverSelectionTimeoutMS: 5_000,
    });
    await client.connect();

    try {
      const db = client.db(dbName);
      const existing = await db.listCollections({ name: collectionName }).toArray();

      if (existing.length) {
        // Update validator
        await db.command({ collMod: collectionName, validator, validationLevel: 'strict' });
      } else {
        await db.createCollection(collectionName, { validator });
        await db.collection(collectionName).createIndex({ owner_id: 1, created_at: -1 });
      }

      this.logger.log(`Collection created/updated: ${collectionName}`);
      return { created: true };
    } finally {
      await client.close();
    }
  }

  async dropCollection(
    connectionString: string,
    dbName: string,
    collectionName: string,
  ): Promise<{ dropped: boolean }> {
    const client = new MongoClient(connectionString, {
      maxPoolSize: 5,
      serverSelectionTimeoutMS: 5_000,
    });
    await client.connect();

    try {
      await client.db(dbName).dropCollection(collectionName);
      this.logger.warn(`Collection dropped: ${collectionName}`);
      return { dropped: true };
    } finally {
      await client.close();
    }
  }

  async listCollections(connectionString: string, dbName: string): Promise<string[]> {
    const client = new MongoClient(connectionString, {
      maxPoolSize: 5,
      serverSelectionTimeoutMS: 5_000,
    });
    await client.connect();

    try {
      const cols = await client.db(dbName).listCollections().toArray();
      return cols.map((c) => c.name);
    } finally {
      await client.close();
    }
  }
}
