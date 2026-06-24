// ============================================================
// Relation: animal_with_health
//
// Cross-database join definition for the BaaS .join() API.
// Lets the frontend fetch a Mongo animal document with its
// PostgreSQL health records attached in a single call:
//
//   baas.collection('animals')
//       .join('animal_with_health')
//       .eq('_id', animalId)
//       .single()
// ============================================================

module.exports = {
  name: 'animal_with_health',

  // Left side: MongoDB document
  from: {
    database: 'mongo',
    collection: 'animals',
    localField: '_id',           // ObjectId as string
  },

  // Right side: PostgreSQL table
  to: {
    database: 'postgres',
    table: 'health_records',
    foreignField: 'animal_id',   // stored as TEXT matching Mongo _id
  },

  type: 'one_to_many',          // one animal → many health records
  as: 'health_records',         // nested key in the response

  // Default sort for the joined records
  orderBy: { recorded_at: 'desc' },

  // Optional limit per parent (avoids loading thousands of records)
  limit: 50,
};
