// `@jest/globals` (bundled with jest) provides the typings — the monorepo does
// not ship `@types/jest`, so the globals must be imported explicitly.
import { describe, expect, it } from '@jest/globals';
import { BadRequestException } from '@nestjs/common';
import { buildColumnDef } from './postgres-schema.engine';
import type { ColumnDefinition } from '../schemas/dto/schema.dto';

// buildColumnDef is the pure CWE-89 allow-list guard extracted from createTable:
// it validates a request-controlled column (type / name / DEFAULT) and returns
// the DDL fragment, throwing BadRequestException on anything not allow-listed.
// Exercised directly here — no live Postgres needed.
function col(overrides: Partial<ColumnDefinition>): ColumnDefinition {
  return { name: 'title', type: 'text', ...overrides } as ColumnDefinition;
}

describe('buildColumnDef', () => {
  it('emits NOT NULL by default and lowercases the validated type', () => {
    expect(buildColumnDef(col({ type: 'TEXT' }))).toBe('"title" text NOT NULL');
  });

  it('omits NOT NULL for a nullable column and appends UNIQUE', () => {
    expect(buildColumnDef(col({ nullable: true, unique: true }))).toBe('"title" text UNIQUE');
  });

  it('appends an allow-listed niladic-function DEFAULT (trimmed)', () => {
    expect(buildColumnDef(col({ type: 'timestamptz', default_value: '  now()  ' })))
      .toBe('"title" timestamptz NOT NULL DEFAULT now()');
  });

  it('accepts a quoted string-literal DEFAULT', () => {
    expect(buildColumnDef(col({ default_value: "'draft'" })))
      .toBe(`"title" text NOT NULL DEFAULT 'draft'`);
  });

  it('rejects a type that is not on the allow-list', () => {
    expect(() => buildColumnDef(col({ type: 'money' }))).toThrow(BadRequestException);
  });

  it('rejects a column name that is not a bare identifier (CWE-89)', () => {
    for (const name of ['has space', 'a;b', 'evil"name', 'drop--it', '1leading']) {
      expect(() => buildColumnDef(col({ name }))).toThrow(BadRequestException);
    }
  });

  it('rejects a DEFAULT that is not on the safe allow-list (CWE-89)', () => {
    for (const dv of ["1); DROP TABLE users;--", 'pg_sleep(10)', '(SELECT 1)']) {
      expect(() => buildColumnDef(col({ default_value: dv }))).toThrow(BadRequestException);
    }
  });
});
