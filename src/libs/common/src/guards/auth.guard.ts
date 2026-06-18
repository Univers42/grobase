/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   auth.guard.ts                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 22:30:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { CanActivate, ExecutionContext, Injectable, UnauthorizedException } from '@nestjs/common';
import { Request } from 'express';
import { identityToUserContext, resolveRequestIdentity } from '../identity/request-identity';

/**
 * Populates verified request identity and legacy req.user compatibility state.
 */
@Injectable()
export class AuthGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const req = context.switchToHttp().getRequest<Request>();
    const identity = resolveRequestIdentity(req, true);
    if (!identity) throw new UnauthorizedException('Missing verified identity');
    req.identity = identity;
    req.user = identityToUserContext(identity, req.headers['x-user-email'] as string | undefined);
    return true;
  }
}
