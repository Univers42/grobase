// ============================================================
// Access Rules — MongoDB collections (animals, feeding_logs,
//                events, visitor_messages)
//
// DSL consumed by the BaaS runtime to enforce per-role RBAC
// on every collection operation.
// ============================================================

module.exports = {
  // ── Animals ─────────────────────────────────────────────────
  animals: {
    read: ['*'],                        // everyone can read
    create: ['admin', 'zookeeper'],
    update: ['admin', 'zookeeper', 'vet'],
    delete: ['admin'],

    // Field-level restrictions
    fields: {
      // Only admins can change the is_featured flag
      is_featured: { update: ['admin'] },
      // Only keepers & admins can change feeding_schedule
      feeding_schedule: { update: ['admin', 'zookeeper'] },
    },

    // Row-level filter: visitors only see active animals
    filters: {
      visitor: { status: 'active' },
    },
  },

  // ── Feeding Logs ────────────────────────────────────────────
  feeding_logs: {
    read: ['admin', 'zookeeper', 'vet'],
    create: ['admin', 'zookeeper'],
    update: ['admin'],                   // corrections only
    delete: ['admin'],
  },

  // ── Events ──────────────────────────────────────────────────
  events: {
    read: ['*'],
    create: ['admin'],
    update: ['admin'],
    delete: ['admin'],

    filters: {
      // Public visitors only see active events
      visitor: { is_active: true },
    },
  },

  // ── Visitor Messages ────────────────────────────────────────
  visitor_messages: {
    read: ['admin', 'reception'],
    create: ['*'],                       // anyone can submit a contact form
    update: ['admin', 'reception'],      // only staff can reply / change status
    delete: ['admin'],
  },
};
