/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   roles.guard.ts                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 22:30:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Injectable,
  SetMetadata,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { Request } from 'express';

export const ROLES_KEY = 'roles';

/**
 * Decorator to specify required roles on a controller or handler.
 * @example @Roles('service_role', 'admin')
 */
export const Roles = (...roles: string[]) => SetMetadata(ROLES_KEY, roles);

/**
 * Guard that checks req.user.role against @Roles() metadata.
 * Must be used AFTER AuthGuard (needs req.user populated).
 */
@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const requiredRoles = this.reflector.getAllAndOverride<string[]>(ROLES_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);

    if (!requiredRoles?.length) {
      return true; // no roles restriction
    }

    const req = context.switchToHttp().getRequest<Request>();
    const userRole = req.identity?.role ?? req.user?.role;
    const roleNames = req.identity?.roleNames ?? (userRole ? [userRole] : []);

    if (!roleNames.some((role) => requiredRoles.includes(role))) {
      throw new ForbiddenException(
        `Insufficient permissions — requires one of: ${requiredRoles.join(', ')}`,
      );
    }

    return true;
  }
}
