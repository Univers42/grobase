/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema.ts                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/09 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/09 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { routes } from '../core/routes.js';
import type { HttpClient } from '../core/http.js';
import type { NormalizedSchema, SchemaDdlInput, SchemaDdlOp, SchemaDdlResult } from '../types.js';

/** Ops that destroy data — refused client-side without `confirm: true`,
 *  mirroring the server's 400 guard (same set as the query-router). */
const DESTRUCTIVE_DDL_OPS: ReadonlySet<SchemaDdlOp> = new Set(['drop_column', 'drop_table']);

/**
 * Engine-agnostic schema introspection + DDL
 * (`GET /query/v1/:dbId/schema`, `POST /query/v1/:dbId/schema/ddl`).
 *
 * `describe()` returns the mount's tables/collections with normalized column
 * types plus the engine's live capability descriptor; `ddl()` applies ONE
 * schema operation per request. Engines without an introspection/DDL surface
 * (redis/http) reject with 422 `unsupported_capability`; an
 * `alter_column_type` the existing data cannot satisfy rejects with 409.
 */
export class SchemaClient {
  constructor(private readonly http: HttpClient) {}

  /** Describe `dbId`'s schema (tables, normalized columns, live capabilities). */
  describe(dbId: string): Promise<NormalizedSchema> {
    return this.http.request<NormalizedSchema>(routes.query.schema(dbId), { method: 'GET' });
  }

  /**
   * Apply ONE schema-DDL operation to `dbId`. Destructive ops (`drop_column`,
   * `drop_table`) are refused **before any request is sent** unless
   * `confirm: true` — the same contract the server enforces with a 400.
   */
  ddl(dbId: string, input: SchemaDdlInput): Promise<SchemaDdlResult> {
    if (DESTRUCTIVE_DDL_OPS.has(input.op) && (input as { confirm?: boolean }).confirm !== true) {
      throw new Error(
        `ddl op '${input.op}' is destructive — set "confirm": true to proceed (request not sent)`,
      );
    }

    return this.http.request<SchemaDdlResult>(routes.query.schemaDdl(dbId), {
      method: 'POST',
      body: input,
    });
  }
}
