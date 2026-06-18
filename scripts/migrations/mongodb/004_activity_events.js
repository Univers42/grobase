/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   004_activity_events.js                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// File: scripts/migrations/mongodb/004_activity_events.js
// Migration 004: Activity events — time-series user analytics
// Stores login, page-view, API-call, feature-usage events with a 90-day TTL.
// Powers the user-analytics Grafana dashboard.

db = db.getSiblingDB(process.env.MONGO_INITDB_DATABASE || 'mini_baas');

// ── Guard: skip if already applied ──────────────────────────────
if (db.schema_migrations.findOne({ version: 4 })) {
  print('Migration 004 already applied — skipping');
  quit(0);
}

// ── 1. activity_events collection ───────────────────────────────
db.createCollection('activity_events', {
  validator: {
    $jsonSchema: {
      bsonType: 'object',
      required: ['user_id', 'event_type', 'timestamp'],
      properties: {
        user_id: {
          bsonType: 'string',
          description: 'UUID of the acting user (matches auth.users.id)'
        },
        event_type: {
          bsonType: 'string',
          enum: [
            'login',
            'logout',
            'signup',
            'mfa_enroll',
            'mfa_verify',
            'password_change',
            'api_call',
            'page_view',
            'file_upload',
            'file_download',
            'query_execute',
            'permission_denied',
            'feature_use'
          ],
          description: 'Canonical event name'
        },
        timestamp: {
          bsonType: 'date',
          description: 'When the event occurred (used by TTL index)'
        },
        metadata: {
          bsonType: 'object',
          description: 'Event-specific payload: route, method, status, duration_ms, ip, user_agent …'
        },
        tenant_id: {
          bsonType: 'string',
          description: 'Optional tenant scope'
        },
        session_id: {
          bsonType: 'string',
          description: 'Optional session/correlation ID'
        }
      }
    }
  }
});

// ── 2. Indexes ──────────────────────────────────────────────────
// TTL: auto-delete after 90 days
db.activity_events.createIndex(
  { timestamp: 1 },
  { expireAfterSeconds: 7776000, name: 'idx_ae_ttl_90d' }   // 90 * 86400
);

// Per-user timeline
db.activity_events.createIndex(
  { user_id: 1, timestamp: -1 },
  { name: 'idx_ae_user_time' }
);

// Per-type aggregation (dashboards)
db.activity_events.createIndex(
  { event_type: 1, timestamp: -1 },
  { name: 'idx_ae_type_time' }
);

// Per-tenant (multi-tenant analytics)
db.activity_events.createIndex(
  { tenant_id: 1, event_type: 1, timestamp: -1 },
  { name: 'idx_ae_tenant_type_time' }
);

print('✓ activity_events collection created with TTL + analytics indexes');

// ── 3. Seed sample events ───────────────────────────────────────
const sampleUserId = '00000000-0000-0000-0000-000000000000';
db.activity_events.insertMany([
  {
    user_id: sampleUserId,
    event_type: 'signup',
    timestamp: new Date(),
    metadata: { provider: 'email', ip: '127.0.0.1' },
    tenant_id: 'default'
  },
  {
    user_id: sampleUserId,
    event_type: 'login',
    timestamp: new Date(),
    metadata: { provider: 'email', ip: '127.0.0.1', user_agent: 'curl/8.0' },
    tenant_id: 'default'
  },
  {
    user_id: sampleUserId,
    event_type: 'api_call',
    timestamp: new Date(),
    metadata: { route: '/rest/v1/user_profiles', method: 'GET', status: 200, duration_ms: 42 },
    tenant_id: 'default'
  }
]);

print('✓ activity_events seeded with sample data');

// ── Record migration ────────────────────────────────────────────
db.schema_migrations.insertOne({
  version: 4,
  name: '004_activity_events',
  applied_at: new Date()
});

print('✓ Migration 004 complete');
