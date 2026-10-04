/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   engines.ts                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/01 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/04 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// **Generated** engine catalog (M10): what GET /query/v1/engines returns for
// the engines compose forwards to the Rust data plane by default — each Rust
// descriptor mapped by toEngineCaps in
// src/apps/query-router/src/query/engines.controller.ts.
//
// Regenerate from a live stack:  cd sdks/js && node ./scripts/codegen-engines.mjs
// data-plane-core's sdk_engine_catalog test fails when this drifts from the
// Rust descriptors.

export const ENGINE_CAPS = {
  postgresql: { read: true, write: true, upsert: true, txIntra: true, stream: true, semantic: { joins: 'native', patternSearch: 'native', ddl: true, migrationVersioning: true, latencyClass: 'native' } },
  cockroachdb: { read: true, write: true, upsert: true, txIntra: true, stream: false, semantic: { joins: 'native', patternSearch: 'native', ddl: true, migrationVersioning: true, latencyClass: 'native' } },
  mongodb: { read: true, write: true, upsert: true, txIntra: false, stream: true, semantic: { joins: 'limited', patternSearch: 'indexed', ddl: false, migrationVersioning: false, latencyClass: 'native' } },
  mysql: { read: true, write: true, upsert: true, txIntra: true, stream: false, semantic: { joins: 'native', patternSearch: 'indexed', ddl: true, migrationVersioning: true, latencyClass: 'native' } },
  mariadb: { read: true, write: true, upsert: true, txIntra: true, stream: false, semantic: { joins: 'native', patternSearch: 'indexed', ddl: true, migrationVersioning: true, latencyClass: 'native' } },
  redis: { read: true, write: true, upsert: true, txIntra: false, stream: false, semantic: { joins: 'none', patternSearch: 'none', ddl: false, migrationVersioning: false, latencyClass: 'native' } },
  sqlite: { read: true, write: true, upsert: true, txIntra: false, stream: false, semantic: { joins: 'native', patternSearch: 'indexed', ddl: false, migrationVersioning: false, latencyClass: 'native' } },
  mssql: { read: true, write: true, upsert: true, txIntra: false, stream: false, semantic: { joins: 'native', patternSearch: 'indexed', ddl: false, migrationVersioning: false, latencyClass: 'native' } },
  http: { read: true, write: true, upsert: true, txIntra: false, stream: false, semantic: { joins: 'none', patternSearch: 'remote', ddl: false, migrationVersioning: false, latencyClass: 'remote' } },
} as const;

export type EngineId = keyof typeof ENGINE_CAPS;

export type EngineCaps<E extends EngineId = EngineId> = (typeof ENGINE_CAPS)[E];

export const ENGINE_IDS = Object.keys(ENGINE_CAPS) as EngineId[];

/** Engines that advertise `stream: true` (can be subscribed to). */
export type StreamableEngine = {
  [E in EngineId]: (typeof ENGINE_CAPS)[E]['stream'] extends true ? E : never;
}[EngineId];

/** Engines that advertise `txIntra: true` (support intra-engine transactions). */
export type TransactionalEngine = {
  [E in EngineId]: (typeof ENGINE_CAPS)[E]['txIntra'] extends true ? E : never;
}[EngineId];

/** Engines that advertise `upsert: true`. */
export type UpsertableEngine = {
  [E in EngineId]: (typeof ENGINE_CAPS)[E]['upsert'] extends true ? E : never;
}[EngineId];

/** Runtime introspection — keep this in lockstep with `EnginesController`. */
export interface EngineDescriptor {
  engine: EngineId;
  capabilities: EngineCaps;
}

export interface EnginesResponse {
  engines: EngineId[];
  details: EngineDescriptor[];
}
