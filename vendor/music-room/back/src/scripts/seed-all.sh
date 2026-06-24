#!/bin/bash
# Seed all data in correct order
set -e

echo "╔══════════════════════════════════════╗"
echo "║   Music Room - Database Seeder       ║"
echo "╚══════════════════════════════════════╝"
echo ""

FORCE_FLAG=""
if [[ "$1" == "--force" ]]; then
  FORCE_FLAG="--force"
  echo "⚠️  Force mode: existing data will be cleared"
  echo ""
fi

echo "Step 1/3: Seeding users..."
npx ts-node -r tsconfig-paths/register src/scripts/seed-users.ts $FORCE_FLAG

echo "Step 2/3: Seeding events..."
npx ts-node -r tsconfig-paths/register src/scripts/seed-events.ts $FORCE_FLAG

echo "Step 3/3: Seeding playlists..."
npx ts-node -r tsconfig-paths/register src/scripts/seed-playlists.ts $FORCE_FLAG

echo "╔══════════════════════════════════════╗"
echo "║   ✅ All seeds completed!             ║"
echo "╚══════════════════════════════════════╝"
