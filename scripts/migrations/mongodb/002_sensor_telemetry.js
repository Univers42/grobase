/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   002_sensor_telemetry.js                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// File: scripts/migrations/mongodb/002_sensor_telemetry.js
// Migration: Create sensor_telemetry collection with time-series support
// Run with: mongosh <uri> scripts/migrations/mongodb/002_sensor_telemetry.js

const DB_NAME = process.env.MONGO_DB_NAME || 'mini_baas';
const COLLECTION = 'sensor_telemetry';

const db = db || connect(`mongodb://localhost:27017/${DB_NAME}`);

const existing = db.getCollectionNames().filter(n => n === COLLECTION);
if (existing.length === 0) {
  db.createCollection(COLLECTION, {
    validator: {
      $jsonSchema: {
        bsonType: 'object',
        required: ['owner_id', 'device_id', 'metric', 'value', 'timestamp'],
        properties: {
          owner_id:   { bsonType: 'string', minLength: 1 },
          device_id:  { bsonType: 'string', minLength: 1, maxLength: 128 },
          metric:     { bsonType: 'string', minLength: 1, maxLength: 64 },
          value:      { bsonType: 'double' },
          unit:       { bsonType: 'string', maxLength: 16 },
          timestamp:  { bsonType: 'date' },
          metadata:   { bsonType: 'object' },
        },
      },
    },
    validationLevel: 'strict',
    validationAction: 'error',
  });
  print(`Created collection: ${COLLECTION}`);
} else {
  print(`Collection ${COLLECTION} already exists, skipping creation.`);
}

// Compound index for owner queries
db[COLLECTION].createIndex({ owner_id: 1, device_id: 1, timestamp: -1 });
// TTL index: auto-expire telemetry after 30 days
db[COLLECTION].createIndex({ timestamp: 1 }, { expireAfterSeconds: 2592000 });

print(`Indexes ensured on ${COLLECTION}`);
