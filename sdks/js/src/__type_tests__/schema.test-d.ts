/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema.test-d.ts                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/09 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/09 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// **Compile-time** assertions for the M22 schema introspection + DDL surface.
//
// This file is **expected to compile** under `tsc --noEmit`. If TypeScript
// complains, the schema wire typing has drifted. The `// @ts-expect-error`
// lines are the inverse: they MUST trigger an error — if the line silently
// compiles, the type narrowing is broken and the SDK lies to its users.
//
// To verify locally:
//   cd apps/baas/sdk && npx tsc --noEmit -p tsconfig.typecheck.json

import type {
  ColumnSchema,
  NormalizedSchema,
  NormalizedType,
  SchemaClient,
  SchemaDdlInput,
  SchemaDdlResult,
} from '../index.js';

// ── 1) NormalizedType is a closed literal union ──────────────────────────────
const text: NormalizedType = 'text';
text satisfies unknown;
const objectId: NormalizedType = 'objectid';
objectId satisfies unknown;

// @ts-expect-error 'varchar' is an engine-native name, not a normalized type
const varchar: NormalizedType = 'varchar';
varchar satisfies unknown;

// @ts-expect-error 'string' is not in the normalized union (use 'text')
const str: NormalizedType = 'string';
str satisfies unknown;

// ── 2) describe() wire shape (exact snake_case contract) ────────────────────
const described: NormalizedSchema = {
  dbId: '4ee63a30-0000-0000-0000-000000000000',
  engine: 'postgresql',
  capabilities: null, // the capabilities fetch may fail — null is contractual
  tables: [
    {
      name: 'todos',
      primary_key: ['id'],
      columns: [
        {
          name: 'id',
          native_type: 'uuid',
          normalized_type: 'uuid',
          nullable: false,
          default: 'gen_random_uuid()',
          enum_values: null,
          references: null,
          inferred: false,
        },
        {
          name: 'owner_id',
          native_type: 'uuid',
          normalized_type: 'uuid',
          nullable: false,
          default: null,
          enum_values: null,
          references: { table: 'users', column: 'id' },
          inferred: false,
        },
      ],
    },
  ],
};
described satisfies unknown;

// Capabilities mirror the live engine descriptor (loose for forward-compat).
const withCaps: NormalizedSchema['capabilities'] = {
  read: true, write: true, upsert: false, batch: true, aggregate: true,
  introspect: true, schema_ddl: true, stream: false, ddl: true, transactions: true,
  savepoints: true, // unknown extra flags are allowed (index signature)
};
withCaps satisfies unknown;

// @ts-expect-error references must be `{ table, column } | null`, not a string
const badColumn: ColumnSchema = { name: 'x', native_type: 't', normalized_type: 'text', nullable: true, default: null, enum_values: null, references: 'todos.id', inferred: false };
badColumn satisfies unknown;

// ── 3) DDL inputs: per-op required fields ────────────────────────────────────
const addColumn: SchemaDdlInput = { op: 'add_column', table: 'todos', column: { name: 'done', normalized_type: 'boolean', nullable: false, default: 'false' } };
addColumn satisfies unknown;

const alterType: SchemaDdlInput = { op: 'alter_column_type', table: 'todos', column: { name: 'count', normalized_type: 'integer' } };
alterType satisfies unknown;

const createTable: SchemaDdlInput = { op: 'create_table', table: 'notes', columns: [{ name: 'id', normalized_type: 'uuid', nullable: false }], primary_key: ['id'] };
createTable satisfies unknown;

// @ts-expect-error DDL cannot create describe-only types (objectid/unknown)
const addObjectId: SchemaDdlInput = { op: 'add_column', table: 'todos', column: { name: 'ref', normalized_type: 'objectid' } };
addObjectId satisfies unknown;

// @ts-expect-error create_table requires primary_key
const createNoPk: SchemaDdlInput = { op: 'create_table', table: 'notes', columns: [{ name: 'id', normalized_type: 'uuid' }] };
createNoPk satisfies unknown;

// @ts-expect-error add_column requires the column definition
const addNoColumn: SchemaDdlInput = { op: 'add_column', table: 'todos' };
addNoColumn satisfies unknown;

// ── 4) Destructive ops require `confirm: true` at compile time ──────────────
const dropTable: SchemaDdlInput = { op: 'drop_table', table: 'notes', confirm: true };
dropTable satisfies unknown;

const dropColumn: SchemaDdlInput = { op: 'drop_column', table: 'todos', column_name: 'done', confirm: true };
dropColumn satisfies unknown;

// @ts-expect-error drop_table without confirm must not compile
const dropNoConfirm: SchemaDdlInput = { op: 'drop_table', table: 'notes' };
dropNoConfirm satisfies unknown;

// @ts-expect-error confirm: false is not a confirmation (`true` literal only)
const dropFalseConfirm: SchemaDdlInput = { op: 'drop_table', table: 'notes', confirm: false };
dropFalseConfirm satisfies unknown;

// @ts-expect-error drop_column requires column_name
const dropColNoName: SchemaDdlInput = { op: 'drop_column', table: 'todos', confirm: true };
dropColNoName satisfies unknown;

// ── 5) Client surface returns the wire types ─────────────────────────────────
declare const schema: SchemaClient;
const describePromise: Promise<NormalizedSchema> = schema.describe('db');
describePromise satisfies unknown;
const ddlPromise: Promise<SchemaDdlResult> = schema.ddl('db', dropTable);
ddlPromise satisfies unknown;

const applied: SchemaDdlResult = { op: 'drop_table', table: 'notes', status: 'applied', dbId: 'db' };
applied satisfies unknown;
