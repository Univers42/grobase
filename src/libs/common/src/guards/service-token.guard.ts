/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service-token.guard.ts                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 22:30:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { CanActivate, ExecutionContext, Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Request } from 'express';
import {
  identityToUserContext,
  resolveRequestIdentity,
  serviceIdentityFromHeaders,
} from '../identity/request-identity';
import { Counter, register } from 'prom-client';
import { timingSafeStringEqual } from '../security/service-auth';

const PREVIOUS_ACCEPTED = 'baas_service_token_previous_accepted_total';

/** previousAcceptedCounter returns the rotation-window counter the Go plane also exports. */
function previousAcceptedCounter(): Counter {
  const existing = register.getSingleMetric(PREVIOUS_ACCEPTED);
  if (existing instanceof Counter) return existing;
  return new Counter({
    name: PREVIOUS_ACCEPTED,
    help: 'Service requests authenticated by the previous service token (rotation window open).',
  });
}

/**
 * matchesServiceToken reports whether `presented` is the current service
 * token or, during a rotation window, ADAPTER_REGISTRY_SERVICE_TOKEN_PREV —
 * both compared in constant time; a previous-token match bumps
 * baas_service_token_previous_accepted_total. An empty token never matches.
 */
function matchesServiceToken(config: ConfigService, presented: string | undefined): boolean {
  if (!presented) return false;
  const current = config.get<string>('ADAPTER_REGISTRY_SERVICE_TOKEN');
  if (current && timingSafeStringEqual(presented, current)) return true;
  const previous = config.get<string>('ADAPTER_REGISTRY_SERVICE_TOKEN_PREV');
  if (!previous || !timingSafeStringEqual(presented, previous)) return false;
  previousAcceptedCounter().inc();
  return true;
}

/**
 * Accepts either a service token (X-Service-Token) or Kong user headers.
 * Used by internal endpoints like /databases/:id/connect where
 * query-router calls adapter-registry with a shared secret. This TS↔TS hop
 * (query-router → permission-engine) stays static-token under
 * SERVICE_TOKEN_MODE=hmac: it carries no secrets, and the guard also accepts
 * Kong user headers; the secrets-bearing Go routes are the HMAC ones.
 * During a rotation (scripts/ops/rotate-service-token.sh) the previous token
 * is accepted too, exactly as the Go verifiers do.
 */
@Injectable()
export class ServiceTokenGuard implements CanActivate {
  constructor(private readonly config: ConfigService) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const req = context.switchToHttp().getRequest<Request>();

    const serviceToken = req.headers['x-service-token'] as string | undefined;
    if (matchesServiceToken(this.config, serviceToken)) {
      const serviceId = (req.headers['x-service-id'] as string | undefined) ?? 'internal-service';
      const identity = serviceIdentityFromHeaders(req, serviceId);
      req.identity = identity;
      req.user = identityToUserContext(identity, 'service@internal');
      return true;
    }

    const identity = await resolveRequestIdentity(req, true);
    if (!identity) throw new UnauthorizedException('Missing authentication');
    req.identity = identity;
    req.user = identityToUserContext(identity, req.headers['x-user-email'] as string | undefined);

    return true;
  }
}
