# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    seed-mongo.sh                                      :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
# File: scripts/seed-mongo.sh
# Seed MongoDB with generic BaaS bootstrap data.
# Runs all migrations, then inserts demo documents into mock_catalog.
# Idempotent — safe to run multiple times.
#
# Usage:
#   bash scripts/seed-mongo.sh
#   make seed-mongo
#
# Environment:
#   MONGO_HOST          (default: localhost)
#   MONGO_PORT          (default: 27017)
#   MONGO_USER          (default: mongo)
#   MONGO_PASS          (default: mongo)
#   MONGO_DB            (default: mini_baas)

set -euo pipefail

MONGO_HOST="${MONGO_HOST:-localhost}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_USER="${MONGO_USER:-${MONGO_INITDB_ROOT_USERNAME:-mongo}}"
MONGO_PASS="${MONGO_PASS:-${MONGO_INITDB_ROOT_PASSWORD:-mongo}}"
MONGO_DB="${MONGO_DB:-mini_baas}"

URI="mongodb://${MONGO_USER}:${MONGO_PASS}@${MONGO_HOST}:${MONGO_PORT}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}═══ mini-BaaS MongoDB Seed ═══${NC}"
echo -e "  Host:     ${MONGO_HOST}:${MONGO_PORT}"
echo -e "  Database: ${MONGO_DB}"
echo ""

# ── 1. Run migrations ────────────────────────────────────────────
echo -e "${BOLD}1. Running migrations${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATION_DIR="${SCRIPT_DIR}/migrations/mongodb"

if [[ -d "$MIGRATION_DIR" ]]; then
  for f in $(ls -1 "$MIGRATION_DIR"/*.js 2>/dev/null | sort); do
    fname=$(basename "$f")
    echo -n "  Applying: ${fname}… "
    if docker compose exec -T mongo mongosh --quiet \
      -u "$MONGO_USER" -p "$MONGO_PASS" \
      --authenticationDatabase admin \
      "$MONGO_DB" < "$f" 2>/dev/null; then
      echo -e "${GREEN}OK${NC}"
    else
      echo -e "${YELLOW}SKIP (may already exist)${NC}"
    fi
  done
else
  echo -e "  ${YELLOW}No migrations directory found${NC}"
fi

# ── 2. Insert demo seed documents ────────────────────────────────
echo ""
echo -e "${BOLD}2. Seeding demo documents${NC}"

docker compose exec -T mongo mongosh --quiet \
  -u "$MONGO_USER" -p "$MONGO_PASS" \
  --authenticationDatabase admin \
  "$MONGO_DB" << 'MONGOSH_EOF'

// ── mock_catalog: generic demo documents ─────────────────────────
const now = new Date();
const demoOwner = '00000000-0000-0000-0000-000000000001';

const seedDocs = [
  {
    owner_id: demoOwner,
    title: 'Getting Started Guide',
    body: 'Welcome to mini-BaaS! This is a demo document in the mock_catalog collection.',
    tags: ['demo', 'documentation', 'getting-started'],
    metadata: { priority: 'high', format: 'markdown' },
    created_at: now,
    updated_at: now,
  },
  {
    owner_id: demoOwner,
    title: 'API Integration Example',
    body: 'This document demonstrates how the mongo-api service stores arbitrary JSON.',
    tags: ['demo', 'api', 'example'],
    metadata: { version: 1, status: 'published' },
    created_at: now,
    updated_at: now,
  },
  {
    owner_id: demoOwner,
    title: 'Multi-Tenant Architecture Notes',
    body: 'Each document is scoped to an owner_id, enabling row-level isolation per user.',
    tags: ['architecture', 'multi-tenant', 'security'],
    metadata: { audience: 'developers' },
    created_at: now,
    updated_at: now,
  },
];

const coll = db.getCollection('mock_catalog');
let inserted = 0;
for (const doc of seedDocs) {
  const exists = coll.findOne({ owner_id: doc.owner_id, title: doc.title });
  if (!exists) {
    coll.insertOne(doc);
    inserted++;
  }
}
print(`  mock_catalog: ${inserted} new documents inserted (${seedDocs.length - inserted} already existed)`);

// ── schema_migrations: mark seed as applied ──────────────────────
if (!db.schema_migrations.findOne({ version: 'seed_v1' })) {
  db.schema_migrations.insertOne({
    version: 'seed_v1',
    name: 'demo_seed',
    applied_at: now,
  });
  print('  schema_migrations: seed_v1 marker recorded');
} else {
  print('  schema_migrations: seed_v1 already recorded');
}

print('');
print('Seed complete.');
MONGOSH_EOF

echo ""
echo -e "${GREEN}${BOLD}═══ MongoDB Seed Complete ═══${NC}"
