// ============================================================
// Feeding Logs Collection Schema — MongoDB JSON Schema Validator
// Database: zoo_app | Collection: feeding_logs
// ============================================================

module.exports = {
  collection: 'feeding_logs',
  database: 'mongo',
  schema: {
    bsonType: 'object',
    required: ['animal_id', 'keeper_id', 'food_type', 'quantity_kg', 'fed_at'],
    properties: {
      _id: { bsonType: 'objectId' },
      animal_id: { bsonType: 'objectId' },
      keeper_id: { bsonType: 'string' },
      food_type: { bsonType: 'string' },
      quantity_kg: { bsonType: 'double' },
      fed_at: { bsonType: 'date' },
      notes: { bsonType: 'string' },
      witness: { bsonType: 'string' },
    },
  },
  indexes: [
    { key: { animal_id: 1, fed_at: -1 } },
    { key: { keeper_id: 1, fed_at: -1 } },
    { key: { fed_at: -1 } },
  ],
};
