// ============================================================
// Visitor Messages Collection Schema — MongoDB JSON Schema Validator
// Database: zoo_app | Collection: visitor_messages
// ============================================================

module.exports = {
  collection: 'visitor_messages',
  database: 'mongo',
  schema: {
    bsonType: 'object',
    required: ['visitor_name', 'email', 'subject', 'message', 'created_at'],
    properties: {
      _id: { bsonType: 'objectId' },
      visitor_name: { bsonType: 'string' },
      email: { bsonType: 'string' },
      subject: { bsonType: 'string' },
      message: { bsonType: 'string' },
      status: {
        bsonType: 'string',
        enum: ['unread', 'read', 'replied', 'archived'],
      },
      replied_by: { bsonType: 'string' },
      reply_text: { bsonType: 'string' },
      replied_at: { bsonType: 'date' },
      created_at: { bsonType: 'date' },
    },
  },
  indexes: [
    { key: { status: 1, created_at: -1 } },
    { key: { email: 1 } },
  ],
};
