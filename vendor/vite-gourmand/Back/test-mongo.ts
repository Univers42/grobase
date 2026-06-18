/**
 * MongoDB Atlas Connection Test
 * Run: npx tsx test-mongo.ts
 */
import 'dotenv/config';
import { MongoClient, ServerApiVersion } from 'mongodb';

async function testConnection() {
  const uri = process.env.MONGODB_URI;
  
  if (!uri) {
    console.error('❌ MONGODB_URI not set in .env');
    process.exit(1);
  }

  // Mask password for logging
  const maskedUri = uri.replace(/:[^:@]+@/, ':****@');
  console.log('🔌 Testing connection to:', maskedUri);
  console.log('');

  const client = new MongoClient(uri, {
    serverApi: {
      version: ServerApiVersion.v1,
      strict: true,
      deprecationErrors: true,
    },
  });

  try {
    await client.connect();
    console.log('✅ Connected to MongoDB Atlas!');

    // Ping to confirm
    await client.db('admin').command({ ping: 1 });
    console.log('✅ Ping successful!');

    // Show database info
    const db = client.db('vite_gourmand');
    const collections = await db.listCollections().toArray();
    console.log('📂 Collections in vite_gourmand:', collections.map(c => c.name).join(', ') || 'none');

    // Show stats
    const stats = await db.stats();
    console.log('💾 Database size:', (stats.dataSize / 1024 / 1024).toFixed(2), 'MB');

  } catch (error: any) {
    console.error('❌ Connection failed:', error.message);
    
    if (error.message.includes('Authentication failed')) {
      console.log('');
      console.log('💡 Troubleshooting:');
      console.log('   1. Go to MongoDB Atlas → Database Access');
      console.log('   2. Check if user exists and password is correct');
      console.log('   3. Go to Network Access → Add IP: 0.0.0.0/0');
    }
    
    process.exit(1);
  } finally {
    await client.close();
  }
}

testConnection();
