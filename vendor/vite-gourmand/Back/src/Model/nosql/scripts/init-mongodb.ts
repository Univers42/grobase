/**
 * MongoDB Initialization Script
 * =============================
 * Creates collections and indexes for analytics.
 * Run via: npx tsx src/Model/nosql/scripts/init-mongodb.ts
 */

import { IndexDescription } from 'mongodb';
import { MongoAnalytics, getDb } from '../client/mongo-analytics.client';
import { COLLECTIONS } from '../collections';
import { INDEX_DEFINITIONS } from '../collections/indexes';

async function main(): Promise<void> {
  console.log('[MongoDB Init] Starting initialization...\n');

  try {
    const db = await MongoAnalytics.connect();

    // Create collections
    console.log('[Collections] Creating collections...');
    for (const name of Object.values(COLLECTIONS)) {
      await createCollectionIfNotExists(name);
    }

    // Create indexes
    console.log('\n[Indexes] Creating indexes...');
    for (const def of INDEX_DEFINITIONS) {
      await createIndexes(def.collection, def.indexes);
    }

    // Verify setup
    console.log('\n[Verify] Checking setup...');
    const collections = await db.listCollections().toArray();
    console.log(`  ✅ ${collections.length} collections created`);

    const stats = await db.stats();
    const sizeMB = (stats.dataSize / (1024 * 1024)).toFixed(2);
    console.log(`  💾 Database size: ${sizeMB} MB`);

    console.log('\n[MongoDB Init] ✅ Initialization complete!');
  } catch (error) {
    console.error('[MongoDB Init] ❌ Failed:', error);
    process.exit(1);
  } finally {
    await MongoAnalytics.disconnect();
  }
}

async function createCollectionIfNotExists(name: string): Promise<void> {
  const db = await getDb();
  const collections = await db.listCollections({ name }).toArray();

  if (collections.length === 0) {
    await db.createCollection(name);
    console.log(`  ✅ Created: ${name}`);
  } else {
    console.log(`  ⏭️  Exists: ${name}`);
  }
}

async function createIndexes(
  collectionName: string,
  indexes: IndexDescription[],
): Promise<void> {
  const db = await getDb();
  const collection = db.collection(collectionName);

  for (const index of indexes) {
    try {
      // Build options object only with defined values
      const options: { unique?: boolean; expireAfterSeconds?: number } = {};
      if (index.unique === true) options.unique = true;
      if (typeof index.expireAfterSeconds === 'number') {
        options.expireAfterSeconds = index.expireAfterSeconds;
      }

      const name = await collection.createIndex(index.key, options);
      console.log(`  ✅ ${collectionName}: ${name}`);
    } catch (error) {
      if ((error as Error).message.includes('already exists')) {
        console.log(`  ⏭️  ${collectionName}: index exists`);
      } else {
        throw error;
      }
    }
  }
}

void main();
