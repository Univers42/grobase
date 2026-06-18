// ============================================================
// Animals Collection Schema — MongoDB JSON Schema Validator
// Database: zoo_app | Collection: animals
// ============================================================

module.exports = {
  collection: 'animals',
  database: 'mongo',
  schema: {
    bsonType: 'object',
    required: ['name', 'species', 'zone', 'status', 'birth_date'],
    properties: {
      _id: { bsonType: 'objectId' },
      name: { bsonType: 'string', minLength: 1, maxLength: 100 },
      species: { bsonType: 'string' },
      common_name: { bsonType: 'string' },
      zone: {
        bsonType: 'string',
        enum: [
          'savannah',
          'arctic',
          'rainforest',
          'aquarium',
          'reptile',
          'aviary',
          'petting',
        ],
      },
      status: {
        bsonType: 'string',
        enum: ['active', 'sick', 'quarantine', 'breeding', 'deceased'],
      },
      sex: { bsonType: 'string', enum: ['male', 'female', 'unknown'] },
      birth_date: { bsonType: 'date' },
      arrival_date: { bsonType: 'date' },
      origin_country: { bsonType: 'string' },
      weight_kg: { bsonType: 'double' },
      height_cm: { bsonType: 'double' },
      diet_type: {
        bsonType: 'string',
        enum: ['carnivore', 'herbivore', 'omnivore'],
      },
      feeding_schedule: {
        bsonType: 'array',
        items: {
          bsonType: 'object',
          properties: {
            time: { bsonType: 'string' },
            food_type: { bsonType: 'string' },
            quantity_kg: { bsonType: 'double' },
          },
        },
      },
      conservation_status: {
        bsonType: 'string',
        enum: ['LC', 'NT', 'VU', 'EN', 'CR', 'EW', 'EX'],
      },
      description: { bsonType: 'string' },
      fun_facts: { bsonType: 'array', items: { bsonType: 'string' } },
      photos: { bsonType: 'array', items: { bsonType: 'string' } },
      cover_photo: { bsonType: 'string' },
      last_fed: { bsonType: 'date' },
      total_feedings: { bsonType: 'int', minimum: 0 },
      assigned_keeper: { bsonType: 'string' },
      is_featured: { bsonType: 'bool' },
      created_at: { bsonType: 'date' },
      updated_at: { bsonType: 'date' },
    },
  },
  indexes: [
    { key: { zone: 1, status: 1 } },
    {
      key: { species: 'text', common_name: 'text', description: 'text' },
    },
    { key: { is_featured: 1 } },
    { key: { assigned_keeper: 1 } },
  ],
};
