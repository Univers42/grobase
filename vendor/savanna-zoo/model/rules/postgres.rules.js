// ============================================================
// Access Rules — PostgreSQL tables
//
// These rules complement the RLS policies defined in
// 002_functions_and_triggers.sql. The BaaS runtime sets
// `baas.role` via set_config() before each query.
// ============================================================

module.exports = {
  // ── Staff ───────────────────────────────────────────────────
  staff: {
    read: ['admin', 'zookeeper', 'vet', 'reception'],
    create: ['admin'],
    update: ['admin'],
    delete: ['admin'],

    // Non-admin roles cannot see phone numbers
    fields: {
      phone: { read: ['admin'] },
    },
  },

  // ── Ticket Types ────────────────────────────────────────────
  ticket_types: {
    read: ['*'],                         // public pricing
    create: ['admin'],
    update: ['admin'],
    delete: ['admin'],
  },

  // ── Tickets ─────────────────────────────────────────────────
  tickets: {
    read: ['admin', 'reception'],
    create: ['admin', 'reception'],
    update: ['admin', 'reception'],
    delete: ['admin'],

    fields: {
      visitor_email: { read: ['admin'] },
    },
  },

  // ── Health Records ──────────────────────────────────────────
  health_records: {
    read: ['admin', 'vet', 'zookeeper'],
    create: ['admin', 'vet'],
    update: ['admin', 'vet'],
    delete: ['admin'],
  },

  // ── Staff Schedules ─────────────────────────────────────────
  staff_schedules: {
    read: ['admin', 'zookeeper', 'vet', 'reception'],
    create: ['admin'],
    update: ['admin'],
    delete: ['admin'],
  },

  // ── Visitor Stats (aggregates) ──────────────────────────────
  visitor_stats: {
    read: ['admin'],
    create: [],                          // system-only via trigger
    update: ['admin'],
    delete: [],
  },

  // ── Audit Log ───────────────────────────────────────────────
  audit_log: {
    read: ['admin'],
    create: ['admin', 'zookeeper', 'vet', 'reception'], // all staff
    update: [],                          // immutable
    delete: [],                          // immutable
  },
};
