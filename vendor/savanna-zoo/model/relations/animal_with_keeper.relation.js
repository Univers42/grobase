// ============================================================
// Relation: animal_with_keeper
//
// Cross-database join linking a Mongo animal to its assigned
// PostgreSQL staff member. Used on animal detail pages:
//
//   baas.collection('animals')
//       .join('animal_with_keeper')
//       .eq('_id', animalId)
//       .single()
// ============================================================

module.exports = {
  name: 'animal_with_keeper',

  // Left side: MongoDB document
  from: {
    database: 'mongo',
    collection: 'animals',
    localField: 'assigned_keeper',   // UUID stored as string
  },

  // Right side: PostgreSQL table
  to: {
    database: 'postgres',
    table: 'staff',
    foreignField: 'id',             // UUID primary key
  },

  type: 'many_to_one',              // many animals → one keeper
  as: 'keeper',                     // nested key in the response
};
