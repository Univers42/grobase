/**
 * Database Migration: Create Indexes
 *
 * Run with: npx ts-node src/scripts/create-indexes.ts
 * 
 * Creates all necessary indexes for optimal query performance.
 */

import * as mongoose from 'mongoose';
import * as dotenv from 'dotenv';

dotenv.config();

async function createIndexes() {
  const uri = process.env.MONGODB_URI || 'mongodb://localhost:27017/music-room';
  console.log(`Connecting to: ${uri}`);

  await mongoose.connect(uri);
  const db = mongoose.connection.db;

  console.log('Creating indexes...\n');

  // Users collection
  console.log('--- Users ---');
  await db.collection('users').createIndex({ email: 1 }, { unique: true });
  console.log('  ✓ email (unique)');

  await db.collection('users').createIndex({ username: 1 }, { unique: true });
  console.log('  ✓ username (unique)');

  await db.collection('users').createIndex({ 'socialAuth.googleId': 1 }, { sparse: true });
  console.log('  ✓ socialAuth.googleId (sparse)');

  await db.collection('users').createIndex({ 'socialAuth.facebookId': 1 }, { sparse: true });
  console.log('  ✓ socialAuth.facebookId (sparse)');

  await db.collection('users').createIndex({ verificationToken: 1 }, { sparse: true });
  console.log('  ✓ verificationToken (sparse)');

  await db.collection('users').createIndex({ resetPasswordToken: 1 }, { sparse: true });
  console.log('  ✓ resetPasswordToken (sparse)');

  // Events collection
  console.log('\n--- Events ---');
  await db.collection('events').createIndex({ creator: 1 });
  console.log('  ✓ creator');

  await db.collection('events').createIndex({ location: '2dsphere' });
  console.log('  ✓ location (2dsphere)');

  await db.collection('events').createIndex({ 'timeWindow.start': 1, 'timeWindow.end': 1 });
  console.log('  ✓ timeWindow.start + timeWindow.end (compound)');

  await db.collection('events').createIndex({ tags: 1 });
  console.log('  ✓ tags');

  await db.collection('events').createIndex({ visibility: 1, 'timeWindow.end': -1 });
  console.log('  ✓ visibility + timeWindow.end (compound)');

  // Playlists collection
  console.log('\n--- Playlists ---');
  await db.collection('playlists').createIndex({ creator: 1 });
  console.log('  ✓ creator');

  await db.collection('playlists').createIndex({ collaborators: 1 });
  console.log('  ✓ collaborators');

  await db.collection('playlists').createIndex({ visibility: 1, updatedAt: -1 });
  console.log('  ✓ visibility + updatedAt (compound)');

  // Friends collection
  console.log('\n--- Friends ---');
  await db.collection('friends').createIndex({ requester: 1, recipient: 1 }, { unique: true });
  console.log('  ✓ requester + recipient (unique compound)');

  await db.collection('friends').createIndex({ recipient: 1, status: 1 });
  console.log('  ✓ recipient + status (compound)');

  // Request logs collection
  console.log('\n--- Request Logs ---');
  await db.collection('requestlogs').createIndex({ createdAt: 1 }, { expireAfterSeconds: 2592000 }); // 30 days
  console.log('  ✓ createdAt (TTL: 30 days)');

  await db.collection('requestlogs').createIndex({ userId: 1, createdAt: -1 });
  console.log('  ✓ userId + createdAt (compound)');

  await db.collection('requestlogs').createIndex({ method: 1, path: 1 });
  console.log('  ✓ method + path (compound)');

  // Subscriptions collection
  console.log('\n--- Subscriptions ---');
  await db.collection('subscriptions').createIndex({ userId: 1 }, { unique: true });
  console.log('  ✓ userId (unique)');

  await db.collection('subscriptions').createIndex({ expiresAt: 1 });
  console.log('  ✓ expiresAt');

  // Delegations collection
  console.log('\n--- Delegations ---');
  await db.collection('delegations').createIndex({ deviceId: 1 });
  console.log('  ✓ deviceId');

  await db.collection('delegations').createIndex({ userId: 1, isActive: 1 });
  console.log('  ✓ userId + isActive (compound)');

  console.log('\n✅ All indexes created successfully!');

  // List all indexes
  const collections = await db.listCollections().toArray();
  for (const col of collections) {
    const indexes = await db.collection(col.name).indexes();
    console.log(`\n${col.name}: ${indexes.length} indexes`);
  }

  await mongoose.disconnect();
}

createIndexes().catch((err) => {
  console.error('Failed to create indexes:', err);
  process.exit(1);
});
