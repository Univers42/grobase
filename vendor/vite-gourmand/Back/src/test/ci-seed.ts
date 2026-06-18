/**
 * CI Seed — populates a fresh test database with the minimum data
 * needed for the full e2e test suite to pass.
 *
 * Run with: npx tsx src/test/ci-seed.ts
 */
import { PrismaClient } from '../../generated/prisma/client.js';
import { PrismaPg } from '@prisma/adapter-pg';
import { Pool } from 'pg';
import * as bcrypt from 'bcrypt';

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const adapter = new PrismaPg(pool);
const prisma = new PrismaClient({ adapter });

async function hash(plain: string) {
  return bcrypt.hash(plain, 12);
}

async function main() {
  console.log('🌱  CI seed starting…');

  // ── Roles ──────────────────────────────────────────────────────────────
  const roles = await Promise.all(
    [
      { name: 'superadmin', description: 'Full system access' },
      { name: 'admin', description: 'Business admin' },
      { name: 'employee', description: 'Staff' },
      { name: 'utilisateur', description: 'Client' },
    ].map((r) =>
      prisma.role.upsert({
        where: { name: r.name },
        update: {},
        create: r,
      }),
    ),
  );

  const roleId = (name: string) => roles.find((r) => r.name === name)!.id;

  // ── Test users required by e2e tests ──────────────────────────────────
  const users = [
    {
      email: 'admin@vitegourmand.fr',
      password: await hash('Admin123!'),
      first_name: 'Admin',
      last_name: 'CI',
      role_id: roleId('admin'),
      is_active: true,
      is_email_verified: true,
      gdpr_consent: true,
      gdpr_consent_date: new Date(),
    },
    {
      email: 'manager@vitegourmand.fr',
      password: await hash('Manager123!'),
      first_name: 'Manager',
      last_name: 'CI',
      role_id: roleId('employee'),
      is_active: true,
      is_email_verified: true,
      gdpr_consent: true,
      gdpr_consent_date: new Date(),
    },
    {
      email: 'alice.dupont@email.fr',
      password: await hash('Client123!'),
      first_name: 'Alice',
      last_name: 'Dupont',
      role_id: roleId('utilisateur'),
      is_active: true,
      is_email_verified: true,
      gdpr_consent: true,
      gdpr_consent_date: new Date(),
    },
    {
      email: 'test@test.com',
      password: await hash('Test123!'),
      first_name: 'Test',
      last_name: 'User',
      role_id: roleId('utilisateur'),
      is_active: true,
      is_email_verified: true,
      gdpr_consent: true,
      gdpr_consent_date: new Date(),
    },
  ];

  for (const u of users) {
    await prisma.user.upsert({
      where: { email: u.email },
      update: {},
      create: u,
    });
    console.log(`  ✓ user: ${u.email}`);
  }

  console.log('✅  CI seed done.');
}

main()
  .catch((e) => {
    console.error('❌  CI seed failed:', e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
