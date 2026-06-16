/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   optional-auth.guard.ts                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 22:30:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { Request } from 'express';
import { identityToUserContext, resolveRequestIdentity } from '../identity/request-identity';

/**
 * Like AuthGuard but does not require anonymous requests to carry identity.
 * Use for endpoints that work both authenticated and anonymously.
 */
@Injectable()
export class OptionalAuthGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const req = context.switchToHttp().getRequest<Request>();
    const identity = resolveRequestIdentity(req, false);
    if (!identity) {
      req.identity = undefined;
      req.user = undefined;
      return true;
    }
    req.identity = identity;
    req.user = identityToUserContext(identity, req.headers['x-user-email'] as string | undefined);
    return true;
  }
}
