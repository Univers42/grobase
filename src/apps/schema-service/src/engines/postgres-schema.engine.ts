/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   postgres-schema.engine.ts                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 22:30:37 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { Client } from 'pg';
import { ColumnDefinition } from '../schemas/dto/schema.dto';

const TABLE_REGEX = /^[a-zA-Z_]\w{0,63}$/;
/** Same identifier grammar as the MySQL engine's COLUMN_REGEX — see createTable. */
const COLUMN_REGEX = /^[a-zA-Z_]\w{0,63}$/;
/**
 * Allow-list of safe DEFAULT expressions (the Postgres flavour of the MySQL
 * engine's SAFE_DEFAULT_REGEX): a quoted string literal, a number, a boolean,
 * NULL, or a small set of well-known niladic functions. Anything else — most
 * importantly anything containing a `;`, `)`, or unbalanced quote — is rejected
 * so an attacker cannot smuggle SQL through the otherwise-unquoted DEFAULT clause.
 */
const SAFE_DEFAULT_REGEX =
  /^(CURRENT_TIMESTAMP|CURRENT_DATE|NULL|TRUE|FALSE|-?\d+(\.\d+)?|now\(\)|gen_random_uuid\(\)|'[^']{0,200}')$/i;
const VALID_TYPES = new Set([
  'text', 'varchar', 'char', 'integer', 'int', 'bigint', 'smallint',
  'serial', 'bigserial', 'boolean', 'bool', 'timestamp', 'timestamptz',
  'date', 'time', 'uuid', 'jsonb', 'json', 'numeric', 'decimal',
  'real', 'double precision', 'bytea', 'inet', 'cidr', 'macaddr',
]);

/**
 * Build one validated column DDL fragment from a request-controlled
 * `ColumnDefinition`. Extracted from {@link PostgresSchemaEngine.createTable}
 * both to keep that method under Sonar's cognitive-complexity ceiling (S3776)
 * and so the CWE-89 allow-list checks (type / name / default) are unit-testable
 * without a live Postgres connection. Throws `BadRequestException` on any field
 * that is not allow-listed.
 */
export function buildColumnDef(col: ColumnDefinition): string {
  const type = col.type.toLowerCase();
  if (!VALID_TYPES.has(type)) {
    throw new BadRequestException(`Unsupported column type: ${col.type}`);
  }
  // CWE-89: reject any identifier that is not a bare, quote-free name so the
  // double-quote wrap below cannot be broken out of.
  if (!COLUMN_REGEX.test(col.name)) {
    throw new BadRequestException(`Invalid column name: ${col.name}`);
  }
  let def = `"${col.name}" ${type}`;
  if (!col.nullable) def += ' NOT NULL';
  if (col.unique) def += ' UNIQUE';
  if (col.default_value) {
    // CWE-89: the DEFAULT clause is interpolated unquoted, so it must be a
    // proven-safe literal/known-function — never free-form attacker SQL.
    const dv = col.default_value.trim();
    if (!SAFE_DEFAULT_REGEX.test(dv)) {
      throw new BadRequestException(`Unsafe column default: ${col.default_value}`);
    }
    def += ` DEFAULT ${dv}`;
  }
  return def;
}

@Injectable()
export class PostgresSchemaEngine {
  private readonly logger = new Logger(PostgresSchemaEngine.name);

  /**
   * @brief Create a tenant table, assembling DDL only from whitelist-validated identifiers.
   *
   * @par Vulnerability (CWE-89 SQL Injection)
   * DDL is built by string interpolation from request-controlled
   * `ColumnDefinition` fields. Previously `col.name` was wrapped in double
   * quotes with no escaping (a `"` breaks out of the identifier) and
   * `col.default_value` was concatenated COMPLETELY UNQUOTED. The DDL runs via
   * node-postgres' `client.query(ddl)` (simple query protocol), so a
   * `;`-separated payload executes multiple statements — letting an
   * authenticated caller `DROP` other tenants' tables, disable RLS, or install
   * malicious triggers under the DSN's privileges. The DTO marks both fields as
   * bare `@IsString()`, so the global ValidationPipe passed the attacker text
   * through untouched. The sibling `mysql-schema.engine.ts` already validates the
   * identical DTO with `COLUMN_REGEX` + `SAFE_DEFAULT_REGEX`; the Postgres path
   * was missing the exact discipline the project itself deemed necessary.
   *
   * @par Remediation
   * Every `col.name` is now checked against `COLUMN_REGEX` and every
   * `col.default_value` against the `SAFE_DEFAULT_REGEX` allow-list before
   * interpolation, throwing `BadRequestException` on violation — mirroring the
   * MySQL engine so the rule is engine-agnostic. `col.type` was (and stays)
   * gated on `VALID_TYPES`, and `tableName` on `TABLE_REGEX`. Defense-in-depth
   * `@Matches()` is also added to the DTO boundary (schema.dto.ts).
   *
   * @see https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html#defense-option-4-allow-list-input-validation
   * @see https://cwe.mitre.org/data/definitions/89.html
   */
  async createTable(
    connectionString: string,
    tableName: string,
    columns: ColumnDefinition[],
    enableRls: boolean,
  ): Promise<{ created: boolean; ddl: string }> {
    if (!TABLE_REGEX.test(tableName)) {
      throw new BadRequestException(`Invalid table name: ${tableName}`);
    }

    const colDefs: string[] = [
      `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`,
      `owner_id UUID NOT NULL`,
      `created_at TIMESTAMPTZ DEFAULT now()`,
      `updated_at TIMESTAMPTZ DEFAULT now()`,
    ];

    for (const col of columns) {
      colDefs.push(buildColumnDef(col));
    }

    const ddl = `CREATE TABLE IF NOT EXISTS public."${tableName}" (\n  ${colDefs.join(',\n  ')}\n)`;

    const client = new Client({ connectionString });
    await client.connect();
    try {
      await client.query(ddl);

      if (enableRls) {
        // Create unified helper functions on the external database for RLS evaluation.
        await client.query(`
          CREATE SCHEMA IF NOT EXISTS auth;

          CREATE OR REPLACE FUNCTION auth.current_user_id() RETURNS UUID AS $$
            SELECT COALESCE(
              NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'sub',
              NULLIF(current_setting('app.current_user_id', true), '')
            )::uuid;
          $$ LANGUAGE SQL STABLE;

          CREATE OR REPLACE FUNCTION auth.current_tenant_id() RETURNS UUID AS $$
            SELECT COALESCE(
              NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'tenant_id',
              NULLIF(current_setting('app.current_tenant_id', true), ''),
              auth.current_user_id()::text
            )::uuid;
          $$ LANGUAGE SQL STABLE;

          CREATE OR REPLACE FUNCTION public.current_user_id() RETURNS TEXT AS $$
            SELECT auth.current_user_id()::text;
          $$ LANGUAGE SQL STABLE;

          CREATE OR REPLACE FUNCTION public.current_tenant_id() RETURNS TEXT AS $$
            SELECT auth.current_tenant_id()::text;
          $$ LANGUAGE SQL STABLE;
        `);

        await client.query(`ALTER TABLE public."${tableName}" ENABLE ROW LEVEL SECURITY`);
        await client.query(
          `DO $$ BEGIN
             IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = '${tableName}' AND policyname = 'owner_isolation') THEN
               CREATE POLICY owner_isolation ON public."${tableName}" FOR ALL
                 USING (owner_id::text = auth.current_user_id()::text)
                 WITH CHECK (owner_id::text = auth.current_user_id()::text);
             END IF;
           END $$`,
        );
      }

      // Grant access to common roles if they exist
      await client.query(`
        DO $$ BEGIN
          IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
            EXECUTE format('GRANT ALL ON public.%I TO authenticated', '${tableName}');
          END IF;
          IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
            EXECUTE format('GRANT ALL ON public.%I TO service_role', '${tableName}');
          END IF;
        END $$
      `);

      this.logger.log(`Table created: ${tableName} (RLS=${enableRls})`);
      return { created: true, ddl };
    } finally {
      await client.end();
    }
  }

  async dropTable(connectionString: string, tableName: string): Promise<{ dropped: boolean }> {
    if (!TABLE_REGEX.test(tableName)) {
      throw new BadRequestException(`Invalid table name: ${tableName}`);
    }

    const client = new Client({ connectionString });
    await client.connect();
    try {
      await client.query(`DROP TABLE IF EXISTS public."${tableName}" CASCADE`);
      this.logger.warn(`Table dropped: ${tableName}`);
      return { dropped: true };
    } finally {
      await client.end();
    }
  }

  async listTables(connectionString: string): Promise<string[]> {
    const client = new Client({ connectionString });
    await client.connect();
    try {
      const res = await client.query(
        `SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name`,
      );
      return res.rows.map((r) => r['table_name'] as string);
    } finally {
      await client.end();
    }
  }
}
