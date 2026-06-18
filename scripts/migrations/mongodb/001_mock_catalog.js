/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   001_mock_catalog.js                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// File: scripts/migrations/mongodb/001_mock_catalog.js
// Migration: Create mock_catalog collection with a generic JSON Schema validator.
// The schema is intentionally domain-agnostic — consuming apps should create
// their own collections via the /mongo/v1/collections API.
// Run with: mongosh <uri> scripts/migrations/mongodb/001_mock_catalog.js

const DB_NAME = process.env.MONGO_DB_NAME || 'mini_baas';
const COLLECTION = 'mock_catalog';

const db = db || connect(`mongodb://localhost:27017/${DB_NAME}`);

const SCHEMA = {
  bsonType: 'object',
  required: ['owner_id', 'title', 'created_at', 'updated_at'],
  additionalProperties: true,
  properties: {
    owner_id:   { bsonType: 'string', minLength: 1, description: 'UUID of the owning user' },
    title:      { bsonType: 'string', minLength: 1, maxLength: 200, description: 'Human-readable title' },
    body:       { bsonType: 'string', description: 'Optional free-form content' },
    tags:       { bsonType: 'array', items: { bsonType: 'string' }, description: 'Optional tags' },
    metadata:   { bsonType: 'object', description: 'Arbitrary key-value metadata' },
    created_at: { bsonType: 'date' },
    updated_at: { bsonType: 'date' },
  },
};

const existing = db.getCollectionNames().filter(n => n === COLLECTION);
if (existing.length === 0) {
  db.createCollection(COLLECTION, {
    validator: { $jsonSchema: SCHEMA },
    validationLevel: 'strict',
    validationAction: 'error',
  });
  print(`Created collection: ${COLLECTION}`);
} else {
  db.runCommand({
    collMod: COLLECTION,
    validator: { $jsonSchema: SCHEMA },
    validationLevel: 'strict',
    validationAction: 'error',
  });
  print(`Updated validator for: ${COLLECTION}`);
}

db[COLLECTION].createIndex({ owner_id: 1, created_at: -1 });
print(`Index ensured on ${COLLECTION}: {owner_id: 1, created_at: -1}`);
