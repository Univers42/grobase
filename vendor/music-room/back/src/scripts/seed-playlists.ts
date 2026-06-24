import { NestFactory } from '@nestjs/core';
import { AppModule } from '../app.module';
import { getModelToken } from '@nestjs/mongoose';
import { Model } from 'mongoose';

const PLAYLISTS = [
  {
    name: 'Chill Vibes',
    description: 'Relaxing tracks for unwinding after a long day',
    visibility: 'PUBLIC',
    collaborationType: 'OPEN',
    tags: ['chill', 'relax', 'ambient'],
  },
  {
    name: 'Workout Bangers',
    description: 'High-energy tracks to fuel your gym session',
    visibility: 'PUBLIC',
    collaborationType: 'INVITE_ONLY',
    tags: ['workout', 'energy', 'gym'],
  },
  {
    name: 'Late Night Coding',
    description: 'Focus music for those 2am sessions',
    visibility: 'FRIENDS_ONLY',
    collaborationType: 'OPEN',
    tags: ['focus', 'coding', 'ambient', 'lo-fi'],
  },
  {
    name: 'Road Trip Mix',
    description: 'The perfect playlist for long drives',
    visibility: 'PUBLIC',
    collaborationType: 'VOTE_TO_ADD',
    tags: ['road-trip', 'singalong', 'classic'],
  },
];

async function seed() {
  console.log('🌱 Starting playlists seed...');

  const app = await NestFactory.createApplicationContext(AppModule);
  const PlaylistModel = app.get<Model<any>>(getModelToken('Playlist'));
  const UserModel = app.get<Model<any>>(getModelToken('User'));

  const users = await UserModel.find().limit(3);
  if (users.length === 0) {
    console.error('❌ No users found. Run seed-users first.');
    await app.close();
    return;
  }

  const existingCount = await PlaylistModel.countDocuments();
  if (existingCount > 0 && !process.argv.includes('--force')) {
    console.log(`Found ${existingCount} existing playlists. Skipping. Use --force to reseed.`);
    await app.close();
    return;
  }

  if (process.argv.includes('--force')) {
    await PlaylistModel.deleteMany({});
  }

  for (let i = 0; i < PLAYLISTS.length; i++) {
    const owner = users[i % users.length];
    const collaborators = users
      .filter((u) => u._id.toString() !== owner._id.toString())
      .map((u) => u._id);

    const playlist = new PlaylistModel({
      ...PLAYLISTS[i],
      owner: owner._id,
      collaborators,
      tracks: [],
      version: 0,
    });
    await playlist.save();
    console.log(`  ✅ Created playlist: ${PLAYLISTS[i].name} (by ${owner.username})`);
  }

  console.log(`\n🌱 Playlists seed complete! Created ${PLAYLISTS.length} playlists.\n`);
  await app.close();
}

seed().catch((err) => {
  console.error('❌ Seed failed:', err);
  process.exit(1);
});
