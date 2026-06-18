/**
 * MongoDB Stats Script
 * ====================
 * Displays storage and collection statistics.
 * Run via: npx tsx src/Model/nosql/scripts/stats-mongodb.ts
 */

import { MongoAnalytics } from '../client/mongo-analytics.client';
import { StorageManager } from '../storage/storage-manager';
import { RETENTION_RULES } from '../storage/retention-policy';

async function main(): Promise<void> {
  console.log('[MongoDB Stats] Fetching statistics...\n');

  try {
    await MongoAnalytics.connect();

    const stats = await StorageManager.getStats();

    // Storage overview
    console.log('📊 STORAGE OVERVIEW');
    console.log('='.repeat(50));
    console.log(
      `Total Size: ${stats.totalSizeMB.toFixed(2)} MB / ${stats.maxStorageMB} MB`,
    );
    console.log(`Used:       ${stats.usedPercent.toFixed(1)}%`);
    console.log(
      `Remaining:  ${(stats.maxStorageMB - stats.totalSizeMB).toFixed(2)} MB`,
    );
    console.log('');

    // Threshold check
    const threshold = Number.parseInt(
      process.env.MONGODB_CLEANUP_THRESHOLD_PERCENT || '85',
      10,
    );
    if (stats.usedPercent >= threshold) {
      console.log(`⚠️  WARNING: Storage above ${threshold}% threshold!`);
      console.log('   Run: make mongodb-cleanup');
      console.log('');
    }

    // Collections breakdown
    console.log('📂 COLLECTIONS');
    console.log('='.repeat(50));
    console.log('Name                        Docs       Size    TTL');
    console.log('-'.repeat(50));

    for (const coll of stats.collections) {
      const rule = RETENTION_RULES.find((r) => r.collection === coll.name);
      const ttl = rule ? `${rule.ttlDays}d` : '-';
      const name = coll.name.padEnd(26);
      const docs = String(coll.count).padStart(6);
      const size = `${coll.sizeMB.toFixed(2)} MB`.padStart(10);

      console.log(`${name} ${docs} ${size}    ${ttl}`);
    }

    console.log('');
    console.log('[MongoDB Stats] ✅ Done!');
  } catch (error) {
    console.error('[MongoDB Stats] ❌ Failed:', error);
    process.exit(1);
  } finally {
    await MongoAnalytics.disconnect();
  }
}

void main();
