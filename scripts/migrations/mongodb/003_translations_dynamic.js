/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   003_translations_dynamic.js                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// File: scripts/migrations/mongodb/003_translations_dynamic.js
// Migration 003: Dynamic content translations for multi-tenant i18n
// Stores per-tenant translatable content (labels, descriptions, custom fields).
// Pairs with PostgreSQL 009_translations for UI-string i18n.

db = db.getSiblingDB(process.env.MONGO_INITDB_DATABASE || 'mini_baas');

// ── Guard: skip if already applied ──────────────────────────────
if (db.schema_migrations.findOne({ version: 3 })) {
  print('Migration 003 already applied — skipping');
  quit(0);
}

// ── 1. dynamic_content collection ───────────────────────────────
db.createCollection('dynamic_content', {
  validator: {
    $jsonSchema: {
      bsonType: 'object',
      required: ['tenant_id', 'content_type', 'content_key', 'translations', 'created_at'],
      properties: {
        tenant_id: {
          bsonType: 'string',
          description: 'Tenant / project identifier'
        },
        content_type: {
          bsonType: 'string',
          description: 'Content category: label, description, help_text …'
        },
        content_key: {
          bsonType: 'string',
          description: 'Unique key within content_type + tenant, e.g. "product.title"'
        },
        translations: {
          bsonType: 'object',
          description: 'Map of language-code → translated string, e.g. { "en": "Hello", "fr": "Bonjour" }'
        },
        metadata: {
          bsonType: 'object',
          description: 'Extra context: max_length, placeholder, format hints'
        },
        created_at: { bsonType: 'date' },
        updated_at: { bsonType: 'date' }
      }
    }
  }
});

// Unique per tenant + type + key
db.dynamic_content.createIndex(
  { tenant_id: 1, content_type: 1, content_key: 1 },
  { unique: true, name: 'idx_dc_tenant_type_key' }
);

// Fast look-ups by tenant
db.dynamic_content.createIndex(
  { tenant_id: 1 },
  { name: 'idx_dc_tenant' }
);

print('✓ dynamic_content collection created with indexes');

// ── 2. Seed sample content ──────────────────────────────────────
db.dynamic_content.insertMany([
  {
    tenant_id: 'default',
    content_type: 'label',
    content_key: 'app.title',
    translations: { en: 'Mini BaaS', fr: 'Mini BaaS', ar: 'ميني بي إيه إس' },
    metadata: { max_length: 64 },
    created_at: new Date(),
    updated_at: new Date()
  },
  {
    tenant_id: 'default',
    content_type: 'description',
    content_key: 'app.tagline',
    translations: {
      en: 'Backend-as-a-Service made simple',
      fr: 'Backend en tant que service, simplifié',
      ar: 'خدمة الواجهة الخلفية بسهولة'
    },
    metadata: {},
    created_at: new Date(),
    updated_at: new Date()
  }
]);

print('✓ dynamic_content seeded with sample translations');

// ── Record migration ────────────────────────────────────────────
db.schema_migrations.insertOne({
  version: 3,
  name: '003_translations_dynamic',
  applied_at: new Date()
});

print('✓ Migration 003 complete');
