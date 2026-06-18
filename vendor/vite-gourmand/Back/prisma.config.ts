// Prisma Configuration for Vite Gourmand
// =======================================
// This file configures the Prisma CLI for migrations and schema management.
// For Supabase: The DATABASE_URL uses the pooler (port 6543), and DIRECT_URL uses direct connection (port 5432)
// For Local Docker: Both URLs point to the same local PostgreSQL instance
//
// npm install --save-dev prisma dotenv
import "dotenv/config";
import { defineConfig } from "prisma/config";

// Determine if using Supabase or local based on DB_MODE or URL pattern
const databaseUrl = process.env["DATABASE_URL"] || "";
const directUrl = process.env["DIRECT_URL"] || databaseUrl;
const isSupabase = databaseUrl.includes("supabase") || databaseUrl.includes("pooler");

export default defineConfig({
  // MVC structure: schema lives in src/Model/prisma/
  schema: "src/Model/prisma/schema.prisma",
  migrations: {
    path: "src/Model/prisma/migrations",
  },
  datasource: {
    // For Supabase: use DIRECT_URL for migrations (bypasses pgbouncer)
    // For local: use DATABASE_URL directly
    url: isSupabase ? directUrl : databaseUrl,
  },
});
