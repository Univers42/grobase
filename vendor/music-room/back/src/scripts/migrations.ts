/**
 * Backend database migration helpers.
 * Provides utilities for managing schema migrations in MongoDB.
 */
import { Connection } from 'mongoose';

export interface Migration {
  version: number;
  name: string;
  up: (connection: Connection) => Promise<void>;
  down: (connection: Connection) => Promise<void>;
}

const migrations: Migration[] = [
  {
    version: 1,
    name: 'add-user-preferences',
    up: async (connection: Connection) => {
      const usersCollection = connection.collection('users');
      await usersCollection.updateMany(
        { preferences: { $exists: false } },
        {
          $set: {
            preferences: {
              notifications: true,
              privateProfile: false,
              language: 'en',
              theme: 'system',
            },
          },
        },
      );
    },
    down: async (connection: Connection) => {
      const usersCollection = connection.collection('users');
      await usersCollection.updateMany({}, { $unset: { preferences: '' } });
    },
  },
  {
    version: 2,
    name: 'add-event-tags-index',
    up: async (connection: Connection) => {
      const eventsCollection = connection.collection('events');
      await eventsCollection.createIndex({ tags: 1 });
      await eventsCollection.createIndex({ 'timeWindow.start': 1, 'timeWindow.end': 1 });
    },
    down: async (connection: Connection) => {
      const eventsCollection = connection.collection('events');
      await eventsCollection.dropIndex({ tags: 1 });
      await eventsCollection.dropIndex({ 'timeWindow.start': 1, 'timeWindow.end': 1 });
    },
  },
  {
    version: 3,
    name: 'add-playlist-collaboration',
    up: async (connection: Connection) => {
      const playlistsCollection = connection.collection('playlists');
      await playlistsCollection.updateMany(
        { collaborators: { $exists: false } },
        { $set: { collaborators: [], isCollaborative: false } },
      );
    },
    down: async (connection: Connection) => {
      const playlistsCollection = connection.collection('playlists');
      await playlistsCollection.updateMany(
        {},
        { $unset: { collaborators: '', isCollaborative: '' } },
      );
    },
  },
];

export async function runMigrations(connection: Connection): Promise<void> {
  const migrationsCollection = connection.collection('_migrations');

  const applied = await migrationsCollection.find().sort({ version: -1 }).limit(1).toArray();
  const currentVersion = applied.length > 0 ? applied[0].version : 0;

  const pending = migrations.filter((m) => m.version > currentVersion);

  for (const migration of pending) {
    console.log(`Running migration ${migration.version}: ${migration.name}`);
    await migration.up(connection);
    await migrationsCollection.insertOne({
      version: migration.version,
      name: migration.name,
      appliedAt: new Date(),
    });
    console.log(`Migration ${migration.version} complete`);
  }

  if (pending.length === 0) {
    console.log('No pending migrations');
  }
}

export async function rollbackMigration(connection: Connection): Promise<void> {
  const migrationsCollection = connection.collection('_migrations');

  const applied = await migrationsCollection.find().sort({ version: -1 }).limit(1).toArray();

  if (applied.length === 0) {
    console.log('No migrations to rollback');
    return;
  }

  const lastApplied = applied[0];
  const migration = migrations.find((m) => m.version === lastApplied.version);

  if (!migration) {
    throw new Error(`Migration ${lastApplied.version} not found`);
  }

  console.log(`Rolling back migration ${migration.version}: ${migration.name}`);
  await migration.down(connection);
  await migrationsCollection.deleteOne({ version: migration.version });
  console.log(`Rollback of migration ${migration.version} complete`);
}

export { migrations };
