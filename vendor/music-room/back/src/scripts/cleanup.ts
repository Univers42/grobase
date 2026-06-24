/**
 * Database Migration: Cleanup expired data
 *
 * Run with: npx ts-node src/scripts/cleanup.ts
 * 
 * Removes expired tokens, old logs, and orphaned records.
 */

import * as mongoose from 'mongoose';
import * as dotenv from 'dotenv';

dotenv.config();

async function cleanup() {
  const uri = process.env.MONGODB_URI || 'mongodb://localhost:27017/music-room';
  console.log(`Connecting to: ${uri}`);

  await mongoose.connect(uri);
  const db = mongoose.connection.db;

  const now = new Date();
  console.log(`Starting cleanup at ${now.toISOString()}\n`);

  // 1. Remove expired verification tokens (older than 24h)
  const oneDayAgo = new Date(now.getTime() - 24 * 60 * 60 * 1000);
  const verifyResult = await db.collection('users').updateMany(
    {
      verificationToken: { $exists: true },
      verificationTokenExpires: { $lt: oneDayAgo },
    },
    {
      $unset: { verificationToken: '', verificationTokenExpires: '' },
    },
  );
  console.log(`✓ Expired verification tokens cleaned: ${verifyResult.modifiedCount}`);

  // 2. Remove expired password reset tokens
  const resetResult = await db.collection('users').updateMany(
    {
      resetPasswordToken: { $exists: true },
      resetPasswordExpires: { $lt: now },
    },
    {
      $unset: { resetPasswordToken: '', resetPasswordExpires: '' },
    },
  );
  console.log(`✓ Expired reset tokens cleaned: ${resetResult.modifiedCount}`);

  // 3. Remove old request logs (older than 90 days)
  const ninetyDaysAgo = new Date(now.getTime() - 90 * 24 * 60 * 60 * 1000);
  const logsResult = await db.collection('requestlogs').deleteMany({
    createdAt: { $lt: ninetyDaysAgo },
  });
  console.log(`✓ Old request logs removed: ${logsResult.deletedCount}`);

  // 4. Remove expired subscriptions
  const subResult = await db.collection('subscriptions').updateMany(
    { expiresAt: { $lt: now } },
    { $set: { plan: 'free', features: {} } },
  );
  console.log(`✓ Expired subscriptions reset to free: ${subResult.modifiedCount}`);

  // 5. Remove inactive delegations (older than 30 days)
  const thirtyDaysAgo = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000);
  const delegationResult = await db.collection('delegations').deleteMany({
    isActive: false,
    updatedAt: { $lt: thirtyDaysAgo },
  });
  console.log(`✓ Old inactive delegations removed: ${delegationResult.deletedCount}`);

  // 6. Remove events that ended more than 1 year ago
  const oneYearAgo = new Date(now.getTime() - 365 * 24 * 60 * 60 * 1000);
  const eventResult = await db.collection('events').deleteMany({
    'timeWindow.end': { $lt: oneYearAgo },
  });
  console.log(`✓ Old expired events removed: ${eventResult.deletedCount}`);

  console.log('\n✅ Cleanup completed successfully!');

  await mongoose.disconnect();
}

cleanup().catch((err) => {
  console.error('Cleanup failed:', err);
  process.exit(1);
});
