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
import { timingSafeStringEqual } from '../security/service-auth';

/**
 * Accepts either a service token (X-Service-Token) or Kong user headers.
 * Used by internal endpoints like /databases/:id/connect where
 * query-router calls adapter-registry with a shared secret.
 */
@Injectable()
export class ServiceTokenGuard implements CanActivate {
  constructor(private readonly config: ConfigService) {}

  canActivate(context: ExecutionContext): boolean {
    const req = context.switchToHttp().getRequest<Request>();

    // 1. Try service token
    const serviceToken = req.headers['x-service-token'] as string | undefined;
    const expectedToken = this.config.get<string>('ADAPTER_REGISTRY_SERVICE_TOKEN');

    // Constant-time compare — a `===` on a secret leaks length/prefix timing.
    // This TS↔TS hop (query-router → permission-engine) intentionally stays
    // static-token in both modes: it carries no secrets, and the guard also
    // accepts Kong user headers. The secrets-bearing Go routes are the ones
    // that flip to per-request HMAC under SERVICE_TOKEN_MODE=hmac.
    if (serviceToken && expectedToken && timingSafeStringEqual(serviceToken, expectedToken)) {
      const serviceId = (req.headers['x-service-id'] as string | undefined) ?? 'internal-service';
      const identity = serviceIdentityFromHeaders(req, serviceId);
      req.identity = identity;
      req.user = identityToUserContext(identity, 'service@internal');
      return true;
    }

    const identity = resolveRequestIdentity(req, true);
    if (!identity) throw new UnauthorizedException('Missing authentication');
    req.identity = identity;
    req.user = identityToUserContext(identity, req.headers['x-user-email'] as string | undefined);

    return true;
  }
}
