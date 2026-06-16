/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   capabilities.controller.ts                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/03 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/03 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Controller, Get } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import {
  RustDataPlaneProxy,
  type RustCapabilitiesResponse,
} from '../proxy/rust-data-plane.proxy';

/**
 * Capability introspection surface (gap G6). Proxies the Rust data-plane
 * router's live `/v1/capabilities` — the single source of truth for what each
 * engine can do (read/write/upsert/stream/transactions + cost class) — so the
 * SDK introspects the *runtime* contract instead of a hand-written stub.
 *
 * Routed at ROOT (`@Controller('capabilities')`): Kong's `query-router` service
 * route is `/query/v1` with `strip_path: true`, so a public
 * `GET /query/v1/capabilities` arrives here as `GET /capabilities`.
 *
 * TTL-cached + in-flight-deduplicated by the proxy's shared
 * {@link RustDataPlaneProxy.getCapabilitiesCached} (N3): one cache and one
 * upstream fetch is shared with `/engines`, instead of a per-controller cache.
 */
@ApiTags('introspection')
@Controller('capabilities')
export class CapabilitiesController {
  constructor(private readonly rustProxy: RustDataPlaneProxy) {}

  @Get()
  @ApiOperation({
    summary: 'Live engine capability descriptors (proxied from the Rust data plane)',
    description:
      'Returns the Rust data-plane-router /v1/capabilities payload verbatim: per-engine read/write/upsert/stream/transactions flags plus the cost model (latency_class, pattern_search, joins). The source of truth the SDK is typed against.',
  })
  async list(): Promise<RustCapabilitiesResponse> {
    return this.rustProxy.getCapabilitiesCached();
  }
}
