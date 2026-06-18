// ============================================================
// Events Collection Schema — MongoDB JSON Schema Validator
// Database: zoo_app | Collection: events
// ============================================================

module.exports = {
  collection: 'events',
  database: 'mongo',
  schema: {
    bsonType: 'object',
    required: ['title', 'type', 'start_at', 'end_at', 'zone'],
    properties: {
      _id: { bsonType: 'objectId' },
      title: { bsonType: 'string' },
      type: {
        bsonType: 'string',
        enum: [
          'feeding_show',
          'guided_tour',
          'kids_workshop',
          'night_safari',
          'vip_experience',
        ],
      },
      description: { bsonType: 'string' },
      zone: { bsonType: 'string' },
      start_at: { bsonType: 'date' },
      end_at: { bsonType: 'date' },
      capacity: { bsonType: 'int' },
      price_eur: { bsonType: 'double' },
      is_free: { bsonType: 'bool' },
      animals: { bsonType: 'array', items: { bsonType: 'objectId' } },
      cover_photo: { bsonType: 'string' },
      is_active: { bsonType: 'bool' },
      is_full: { bsonType: 'bool' },
      created_at: { bsonType: 'date' },
    },
  },
  indexes: [
    { key: { start_at: 1, is_active: 1 } },
    { key: { zone: 1 } },
    { key: { type: 1 } },
  ],
};
