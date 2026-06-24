// ============================================================
// Trigger: After INSERT / UPDATE on events → check capacity
//
// When an event's registrations value changes, compare against
// capacity and flip is_full accordingly. Prevents over-booking.
// ============================================================

module.exports = {
  collection: 'events',
  event: ['after_insert', 'after_update'],

  async run({ doc, db }) {
    const isFull = doc.registrations >= doc.capacity;

    // Only write if the flag actually needs to change
    if (doc.is_full !== isFull) {
      await db.collection('events').updateOne(
        { _id: doc._id },
        {
          $set: {
            is_full: isFull,
            updated_at: new Date(),
          },
        },
      );
    }
  },
};
