/**
 * MongoDB Analytics Client
 * ========================
 * Singleton client for MongoDB Atlas connection.
 * Uses connection pooling for optimal performance.
 */

import { MongoClient, Db, ServerApiVersion } from 'mongodb';

let client: MongoClient | null = null;
let db: Db | null = null;

const DB_NAME = 'vite_gourmand';

/**
 * Get MongoDB URI from environment
 */
function getMongoUri(): string {
  const uri = process.env.MONGODB_URI;
  if (!uri) {
    throw new Error('MONGODB_URI environment variable not set');
  }
  return uri;
}

/**
 * Create MongoClient with optimal settings
 */
function createClient(): MongoClient {
  return new MongoClient(getMongoUri(), {
    serverApi: {
      version: ServerApiVersion.v1,
      strict: true,
      deprecationErrors: true,
    },
    maxPoolSize: 10,
    minPoolSize: 1,
    maxIdleTimeMS: 30000,
    connectTimeoutMS: 10000,
  });
}

/**
 * Connect to MongoDB Atlas
 */
export async function connect(): Promise<Db> {
  if (db) return db;

  client = createClient();
  await client.connect();
  db = client.db(DB_NAME);

  console.log('[MongoDB] Connected to Atlas');
  return db;
}

/**
 * Get database instance (auto-connect if needed)
 */
export async function getDb(): Promise<Db> {
  if (!db) {
    return connect();
  }
  return db;
}

/**
 * Disconnect from MongoDB
 */
export async function disconnect(): Promise<void> {
  if (client) {
    await client.close();
    client = null;
    db = null;
    console.log('[MongoDB] Disconnected');
  }
}

/**
 * Ping database to verify connection
 */
export async function ping(): Promise<boolean> {
  try {
    const database = await getDb();
    await database.command({ ping: 1 });
    return true;
  } catch {
    return false;
  }
}

// Export as a namespace for convenience
export const MongoAnalytics = {
  connect,
  getDb,
  disconnect,
  ping,
};
