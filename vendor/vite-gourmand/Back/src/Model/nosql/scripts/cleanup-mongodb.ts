/**
 * MongoDB Cleanup Script
 * ======================
 * Runs storage cleanup based on retention policy.
 * Run via: npx tsx src/Model/nosql/scripts/cleanup-mongodb.ts [--emergency]
 */

import { MongoAnalytics } from '../client/mongo-analytics.client';
import { StorageManager } from '../storage/storage-manager';

async function main(): Promise<void> {
  const isEmergency = process.argv.includes('--emergency');

  console.log(
    `[MongoDB Cleanup] Starting ${isEmergency ? 'EMERGENCY' : 'normal'} cleanup...\n`,
  );

  try {
    await MongoAnalytics.connect();

    // Get current stats
    const statsBefore = await StorageManager.getStats();
    console.log('[Before]');
    console.log(
      `  Total: ${statsBefore.totalSizeMB.toFixed(2)} MB / ${statsBefore.maxStorageMB} MB`,
    );
    console.log(`  Used:  ${statsBefore.usedPercent.toFixed(1)}%`);
    console.log('');

    // Run cleanup
    const deleted = await StorageManager.runCleanup(isEmergency);
    console.log(`\n[Cleanup] Deleted ${deleted} documents`);

    // Get stats after
    const statsAfter = await StorageManager.getStats();
    console.log('\n[After]');
    console.log(
      `  Total: ${statsAfter.totalSizeMB.toFixed(2)} MB / ${statsAfter.maxStorageMB} MB`,
    );
    console.log(`  Used:  ${statsAfter.usedPercent.toFixed(1)}%`);

    const freed = statsBefore.totalSizeMB - statsAfter.totalSizeMB;
    console.log(`  Freed: ${freed.toFixed(2)} MB`);

    console.log('\n[MongoDB Cleanup] ✅ Complete!');
  } catch (error) {
    console.error('[MongoDB Cleanup] ❌ Failed:', error);
    process.exit(1);
  } finally {
    await MongoAnalytics.disconnect();
  }
}

void main();
