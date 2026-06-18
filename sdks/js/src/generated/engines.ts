/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   engines.ts                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/01 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/17 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// **Curated** engine catalog (M10) — the SDK's capability CONTRACT, not a raw
// mirror of the live data-plane. The data plane may technically support more
// (e.g. postgres ON CONFLICT, logical-replication streaming), but the SDK
// deliberately exposes only the capabilities it models generically. The
// compile-time assertions in src/__type_tests__/engines.test-d.ts pin this
// matrix; codegen-engines.mjs can diff it against a live /engines response.
//
// The 5 Rust-backed engines are the only real catalog (the 6 former TS stubs
// were dropped post-audit).
export const ENGINE_CAPS = {
  postgresql: { read: true, write: true, upsert: false, txIntra: true, stream: false, semantic: { joins: 'native', patternSearch: 'native', ddl: true, migrationVersioning: true, latencyClass: 'native' } },
  mongodb: { read: true, write: true, upsert: false, txIntra: false, stream: true, semantic: { joins: 'limited', patternSearch: 'indexed', ddl: true, migrationVersioning: true, latencyClass: 'native' } },
  mysql: { read: true, write: true, upsert: true, txIntra: true, stream: false, semantic: { joins: 'native', patternSearch: 'native', ddl: true, migrationVersioning: true, latencyClass: 'native' } },
  redis: { read: true, write: true, upsert: true, txIntra: false, stream: false, semantic: { joins: 'none', patternSearch: 'none', ddl: false, migrationVersioning: false, latencyClass: 'adapter' } },
  http: { read: true, write: true, upsert: true, txIntra: false, stream: false, semantic: { joins: 'none', patternSearch: 'none', ddl: false, migrationVersioning: false, latencyClass: 'adapter' } },
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
