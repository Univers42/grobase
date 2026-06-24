import { NestFactory } from '@nestjs/core';
import { AppModule } from '../app.module';
import { getModelToken } from '@nestjs/mongoose';
import { Model } from 'mongoose';

const EVENTS = [
  {
    name: 'Friday Night Dance Party',
    description: 'Weekly dance party with the best electronic beats. Open to everyone!',
    licenseType: 'OPEN',
    location: {
      type: 'Point',
      coordinates: [2.3522, 48.8566], // Paris
    },
    timeWindow: {
      start: new Date(Date.now() + 24 * 60 * 60 * 1000), // Tomorrow
      end: new Date(Date.now() + 24 * 60 * 60 * 1000 + 4 * 60 * 60 * 1000), // +4h
    },
    tags: ['dance', 'electronic', 'party', 'open'],
  },
  {
    name: 'Jazz Lounge Evening',
    description: 'Intimate jazz session for invited guests only.',
    licenseType: 'INVITED_ONLY',
    tags: ['jazz', 'lounge', 'intimate'],
  },
  {
    name: 'Park Acoustic Session',
    description: 'Acoustic music in the park. Only available within 500m radius.',
    licenseType: 'GEO_TIME',
    location: {
      type: 'Point',
      coordinates: [2.2945, 48.8584], // Eiffel Tower area
    },
    geoRadius: 500,
    timeWindow: {
      start: new Date(Date.now() + 2 * 24 * 60 * 60 * 1000),
      end: new Date(Date.now() + 2 * 24 * 60 * 60 * 1000 + 3 * 60 * 60 * 1000),
    },
    tags: ['acoustic', 'outdoor', 'park'],
  },
];

async function seed() {
  console.log('🌱 Starting events seed...');

  const app = await NestFactory.createApplicationContext(AppModule);
  const EventModel = app.get<Model<any>>(getModelToken('Event'));
  const UserModel = app.get<Model<any>>(getModelToken('User'));

  // Get first user as creator
  const creator = await UserModel.findOne({ username: 'alice' });
  if (!creator) {
    console.error('❌ No users found. Run seed-users first.');
    await app.close();
    return;
  }

  const existingCount = await EventModel.countDocuments();
  if (existingCount > 0 && !process.argv.includes('--force')) {
    console.log(`Found ${existingCount} existing events. Skipping. Use --force to reseed.`);
    await app.close();
    return;
  }

  if (process.argv.includes('--force')) {
    await EventModel.deleteMany({});
  }

  for (const eventData of EVENTS) {
    const event = new EventModel({
      ...eventData,
      creator: creator._id,
      participants: [creator._id],
    });
    await event.save();
    console.log(`  ✅ Created event: ${eventData.name}`);
  }

  console.log(`\n🌱 Events seed complete! Created ${EVENTS.length} events.\n`);
  await app.close();
}

seed().catch((err) => {
  console.error('❌ Seed failed:', err);
  process.exit(1);
});
