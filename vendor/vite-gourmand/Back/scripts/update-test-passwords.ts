/**
 * Update test user passwords to match Postman collection credentials
 */
import 'dotenv/config';
import { PrismaClient } from '../generated/prisma/client';
import { PrismaPg } from '@prisma/adapter-pg';
import { Pool } from 'pg';
import * as bcrypt from 'bcrypt';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});
const adapter = new PrismaPg(pool);
const prisma = new PrismaClient({ adapter });

async function updatePasswords() {
  // Map Postman expected users to actual database users
  const passwords: Record<string, string> = {
    'jose@vitegourmand.fr': 'Admin123!',      // Admin
    'pierre@vitegourmand.fr': 'Manager123!',  // Employee (as manager)
    'alice@example.fr': 'Client123!',         // Client
  };
  
  console.log('Updating test user passwords...');
  
  for (const [email, password] of Object.entries(passwords)) {
    const hash = await bcrypt.hash(password, 10);
    const result = await prisma.user.updateMany({
      where: { email },
      data: { password: hash }
    });
    console.log(`${email}: ${result.count > 0 ? '✓ Updated' : '✗ Not found'}`);
  }
  
  await prisma.$disconnect();
  await pool.end();
  console.log('Done!');
}

updatePasswords().catch(console.error);
