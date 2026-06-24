// ============================================================
// Trigger: After INSERT on feeding_logs → update parent animal
//
// When a new feeding log is created, atomically:
//   1. Set animals.last_fed = fed_at
//   2. Increment animals.total_feedings by 1
//   3. Touch animals.updated_at
// ============================================================

module.exports = {
  collection: 'feeding_logs',
  event: 'after_insert',

  async run({ doc, db }) {
    const { ObjectId } = require('mongodb');
    const animalId =
      typeof doc.animal_id === 'string'
        ? new ObjectId(doc.animal_id)
        : doc.animal_id;

    await db.collection('animals').updateOne(
      { _id: animalId },
      {
        $set: {
          last_fed: doc.fed_at,
          updated_at: new Date(),
        },
        $inc: { total_feedings: 1 },
      },
    );
  },
};
