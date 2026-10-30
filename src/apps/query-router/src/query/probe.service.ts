/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   probe.service.ts                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import type { VerifiedRequestIdentity } from '@mini-baas/common';
import { QueryService } from './query.service';
import { credentialVersionFor } from './credential-version';
import { RustDataPlaneProxy, RustProxyContext } from '../proxy/rust-data-plane.proxy';

/** Response of `GET /query/v1/:dbId/probe` — the Rust `EngineProbe` (live
 *  server version + TLS posture of the pool's connection) masked by the
 *  mount's placement. Never carries the DSN, the host or any error text:
 *  only ids, the engine name and the masked probe fields. */
export interface ProbeResponse {
  dbId: string;
  engine: string;
  server_version: string;
  tls: string;
  tls_version?: string;
}

interface ProbeCacheEntry {
  value: ProbeResponse;
  expiresAt: number;
}

/**
 * Live engine probe (devil G4): the server version and the TLS posture of
 * the Rust pool's connection for one mount, forwarded to the data plane's
 * `POST /v1/probe` via {@link RustDataPlaneProxy.probe}.
 *
 * Results are TTL-cached in-memory keyed by `${tenantId}:${dbId}:${revision}`
 * (the revision forks the pool, so a rotation must not serve the old
 * connection's answer), capped at a fixed number of entries with simple
 * oldest-entry eviction. A static `DATA_PLANE_MOUNTS` entry is never probed
 * (devil G4 P8), and the version is masked by the mount's placement (P9).
 */
@Injectable()
export class ProbeService {
  private readonly cache = new Map<string, ProbeCacheEntry>();
  private readonly cacheTtlMs: number;
  private readonly cacheMaxEntries: number;

  constructor(
    config: ConfigService,
    private readonly query: QueryService,
    private readonly rustProxy: RustDataPlaneProxy,
  ) {
    // devil G4 P10: the data plane allows 1 probe/s per mount — the cache
    // must absorb the UI, so the TTL is clamped to at least 30s. A non-numeric
    // value falls back too: a NaN expiry would never expire.
    const ttlMs = Number(config.get<string>('QUERY_ROUTER_PROBE_CACHE_TTL_MS', '30000'));
    this.cacheTtlMs = Number.isFinite(ttlMs) ? Math.max(ttlMs, 30_000) : 30_000;
    this.cacheMaxEntries = Number(
      config.get<string>('QUERY_ROUTER_PROBE_CACHE_MAX_ENTRIES', '256'),
    );
  }

  /** Probe `dbId`'s engine for the calling identity (tenant-scoped). */
  async probe(
    dbId: string,
    userId: string,
    identity?: VerifiedRequestIdentity,
  ): Promise<ProbeResponse> {
    // devil G4 P8: static DATA_PLANE_MOUNTS match any tenant, so they are never probed.
    if (this.query.isStaticMount(dbId)) {
      throw new NotFoundException(`Database mount '${dbId}' was not found for this tenant.`);
    }
    const tenantId = identity?.tenantId ?? userId;
    const { engine, connection_string, isolation, revision, location } =
      await this.query.resolveConnection(dbId, tenantId);
    const cacheKey = `${tenantId}:${dbId}:${revision ?? 1}`;
    const cached = this.readCache(cacheKey);
    if (cached) return cached;
    const ctx: RustProxyContext = {
      databaseId: dbId,
      engine,
      tenantId,
      projectId: identity?.projectId,
      appId: identity?.appId,
      userId,
      credentialReference: dbId,
      credentialVersion: credentialVersionFor(revision),
      connectionString: connection_string,
      isolation,
    };
    const probe = await this.rustProxy.probe(ctx);
    const value: ProbeResponse = {
      dbId,
      engine,
      server_version: this.maskVersion(location, probe.server_version),
      tls: probe.tls,
      ...(probe.tls_version ? { tls_version: probe.tls_version } : {}),
    };
    this.writeCache(cacheKey, value);
    return value;
  }

  // devil G4 P9: over-hide, never over-show — a cred-ref mount's DSN never
  // reaches the control plane, so its placement is unknown.
  // Caveat: placement is the classifier's host heuristic (`isPlatformHost`),
  // so a tenant's own LAN host reads as platform and its version is hidden.
  private maskVersion(location: string | undefined, version: string): string {
    if (location === 'platform') return 'platform';
    if (location === 'network' || location === 'file' || location === 'memory') return version;
    return 'unknown';
  }

  private readCache(cacheKey: string): ProbeResponse | undefined {
    const entry = this.cache.get(cacheKey);
    if (!entry) return undefined;
    if (entry.expiresAt <= Date.now()) {
      this.cache.delete(cacheKey);
      return undefined;
    }
    return entry.value;
  }

  private writeCache(cacheKey: string, value: ProbeResponse): void {
    this.evictIfFull();
    this.cache.set(cacheKey, { value, expiresAt: Date.now() + this.cacheTtlMs });
  }

  /** Same policy as SchemaService's cache: lazy-reap expired entries, then
   *  drop the oldest (Map iteration is insertion order) if still over cap. */
  private evictIfFull(): void {
    if (this.cache.size < this.cacheMaxEntries) return;
    const now = Date.now();
    for (const [key, entry] of this.cache) {
      if (entry.expiresAt <= now) this.cache.delete(key);
    }
    if (this.cache.size >= this.cacheMaxEntries) {
      const oldest = this.cache.keys().next().value;
      if (oldest) this.cache.delete(oldest);
    }
  }
}
