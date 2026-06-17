/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   engines.controller.ts                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 23:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 23:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Controller, Get, Logger } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { QueryService, type EngineDescriptor } from './query.service';
import type {
  EngineJoinCapability,
  EngineLatencyClass,
  EnginePatternSearchCapability,
} from '@mini-baas/database';
import {
  RustDataPlaneProxy,
  type RustEngineCapabilities,
} from '../proxy/rust-data-plane.proxy';

// G6: the Rust router's /v1/capabilities is the single source of truth. We map
// its EngineCapabilities (snake_case, with a cost model) into the legacy TS
// `EngineCaps` shape the SDK/M2-verify consume, so /engines no longer ships a
// hand-written stub that can drift from runtime reality. The Rust cost-class
// strings are the same lowercase tokens as the TS unions (native/indexed/scan/
// remote/none/…), so the cast is sound; an unexpected value falls back safely.
const JOIN_VALUES: readonly EngineJoinCapability[] = ['native', 'limited', 'none'];
const PATTERN_VALUES: readonly EnginePatternSearchCapability[] = [
  'native', 'indexed', 'limited', 'scan', 'remote', 'none',
];
const LATENCY_VALUES: readonly EngineLatencyClass[] = ['native', 'adapter', 'fdw', 'remote'];

function pick<T extends string>(value: unknown, allowed: readonly T[], fallback: T): T {
  return allowed.includes(value as T) ? (value as T) : fallback;
}

function toEngineCaps(c: RustEngineCapabilities): EngineDescriptor['capabilities'] {
  return {
    read: !!c.read,
    write: !!c.write,
    upsert: !!c.upsert,
    txIntra: !!c.transactions,
    stream: !!c.stream,
    semantic: {
      joins: pick(c.cost?.joins, JOIN_VALUES, 'none'),
      patternSearch: pick(c.cost?.pattern_search, PATTERN_VALUES, 'none'),
      ddl: !!c.ddl,
      migrationVersioning: !!c.ddl,
      latencyClass: pick(c.cost?.latency_class, LATENCY_VALUES, 'native'),
    },
  };
}

/**
 * Public introspection endpoint — returns the engines this query-router
 * instance can dispatch to. Used by the M2 verify script and the SDK codegen
 * to discover available backends without parsing the source.
 *
 * Post-cutover: the catalog is the union of (a) TS adapters still mounted
 * locally (jdbc/cassandra/neo4j/elasticsearch/qdrant/influx) and
 * (b) engines forwarded to the Rust data-plane-router
 * (postgresql/mongodb/mysql/redis/http).
 */
@ApiTags('introspection')
@Controller('engines')
export class EnginesController {
  private readonly logger = new Logger(EnginesController.name);

  constructor(
    private readonly service: QueryService,
    private readonly rustProxy: RustDataPlaneProxy,
  ) {}

  @Get()
  @ApiOperation({
    summary: 'List engines registered with this query-router',
    description:
      'Returns the engine name (e.g. postgresql, mongodb, mysql, redis, http) and its capability descriptor for each adapter currently mounted. Forwarded-engine capabilities are the live, proxied Rust /v1/capabilities (G6) — no longer a hand-written stub.',
  })
  async list(): Promise<{ engines: string[]; details: EngineDescriptor[] }> {
    const local = this.service.listEngines();
    const forwarded = this.rustProxy.forwardedEngines();
    const localNames = new Set(local.map((d) => d.engine));
    const liveCaps = await this.liveCapsByEngine();
    const forwardedDetails: EngineDescriptor[] = forwarded
      .filter((engine) => !localNames.has(engine))
      .map((engine) => ({ engine, capabilities: liveCaps.get(engine) ?? fallbackCaps() }));
    const details = [...local, ...forwardedDetails];
    return { engines: details.map((d) => d.engine), details };
  }

  /** Map of engine → live TS-shaped caps, from the proxy's shared TTL-cached +
   *  in-flight-deduplicated Rust descriptor (N3: one cache shared with
   *  `/capabilities`, no thundering herd). On a fetch failure we log and return
   *  an empty map (callers fall back to a minimal honest descriptor) so
   *  /engines stays available. */
  private async liveCapsByEngine(): Promise<Map<string, EngineDescriptor['capabilities']>> {
    const out = new Map<string, EngineDescriptor['capabilities']>();
    try {
      const value = await this.rustProxy.getCapabilitiesCached();
      for (const d of value.engines ?? []) {
        out.set(d.engine, toEngineCaps(d.capabilities));
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : 'unknown error';
      this.logger.warn(`live capabilities fetch failed; using fallback caps: ${message}`);
    }
    return out;
  }
}

/** Conservative honest descriptor used only when the Rust router is
 *  unreachable — read-only-safe, never over-claiming a capability. */
function fallbackCaps(): EngineDescriptor['capabilities'] {
  return {
    read: true,
    write: true,
    upsert: true,
    txIntra: false,
    stream: false,
    semantic: {
      joins: 'none',
      patternSearch: 'none',
      ddl: false,
      migrationVersioning: false,
      latencyClass: 'native',
    },
  };
}
