import { NestFactory } from '@nestjs/core';
import { AppModule } from '../app.module';
import { getModelToken } from '@nestjs/mongoose';
import { Model } from 'mongoose';
import * as bcrypt from 'bcrypt';

const USERS = [
  {
    email: 'alice@example.com',
    username: 'alice',
    password: 'Password123!',
    publicInfo: {
      displayName: 'Alice Johnson',
      bio: 'Music lover and event organizer',
      avatarUrl: 'https://api.dicebear.com/7.x/avataaars/svg?seed=alice',
    },
    musicPreferences: {
      favoriteGenres: ['Pop', 'Electronic', 'Indie'],
      favoriteMoods: ['Energetic', 'Chill'],
    },
    isVerified: true,
  },
  {
    email: 'bob@example.com',
    username: 'bob',
    password: 'Password123!',
    publicInfo: {
      displayName: 'Bob Smith',
      bio: 'DJ and playlist curator',
      avatarUrl: 'https://api.dicebear.com/7.x/avataaars/svg?seed=bob',
    },
    musicPreferences: {
      favoriteGenres: ['Hip-Hop', 'R&B', 'Jazz'],
      favoriteMoods: ['Groovy', 'Relaxed'],
    },
    isVerified: true,
  },
  {
    email: 'charlie@example.com',
    username: 'charlie',
    password: 'Password123!',
    publicInfo: {
      displayName: 'Charlie Brown',
      bio: 'Rock enthusiast',
      avatarUrl: 'https://api.dicebear.com/7.x/avataaars/svg?seed=charlie',
    },
    musicPreferences: {
      favoriteGenres: ['Rock', 'Metal', 'Alternative'],
      favoriteMoods: ['Intense', 'Melancholic'],
    },
    isVerified: true,
  },
];

async function seed() {
  console.log('🌱 Starting database seed...');

  const app = await NestFactory.createApplicationContext(AppModule);
  const UserModel = app.get<Model<any>>(getModelToken('User'));

  // Clear existing data
  const existingCount = await UserModel.countDocuments();
  if (existingCount > 0) {
    console.log(`Found ${existingCount} existing users. Skipping seed.`);
    console.log('Use --force flag to reseed.');
    if (!process.argv.includes('--force')) {
      await app.close();
      return;
    }
    console.log('Force flag detected. Clearing existing users...');
    await UserModel.deleteMany({});
  }

  for (const userData of USERS) {
    const hashedPassword = await bcrypt.hash(userData.password, 12);
    const user = new UserModel({
      ...userData,
      password: hashedPassword,
    });
    await user.save();
    console.log(`  ✅ Created user: ${userData.username} (${userData.email})`);
  }

  console.log(`\n🌱 Seed complete! Created ${USERS.length} users.`);
  console.log('Default password for all users: Password123!\n');

  await app.close();
}

seed().catch((err) => {
  console.error('❌ Seed failed:', err);
  process.exit(1);
});
