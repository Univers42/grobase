/**
 * Roles Guard
 * Restricts access based on user roles
 */
import {
  Injectable,
  CanActivate,
  ExecutionContext,
  ForbiddenException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { ROLES_KEY } from '../decorators/roles.decorator';
import { IS_PUBLIC_KEY } from '../decorators/public.decorator';
import type { AuthenticatedRequest } from '../types/request.types';

@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  /**
   * Check if user has required role
   */
  canActivate(context: ExecutionContext): boolean {
    if (this.isPublicRoute(context)) {
      return true;
    }

    const requiredRoles = this.getRequiredRoles(context);
    if (!requiredRoles || requiredRoles.length === 0) {
      return true;
    }

    const user = this.extractUser(context);
    return this.validateUserRole(user, requiredRoles);
  }

  private isPublicRoute(context: ExecutionContext): boolean {
    return (
      this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
        context.getHandler(),
        context.getClass(),
      ]) ?? false
    );
  }

  private getRequiredRoles(context: ExecutionContext): string[] | undefined {
    return this.reflector.getAllAndOverride<string[]>(ROLES_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
  }

  private extractUser(context: ExecutionContext) {
    const request = context.switchToHttp().getRequest<AuthenticatedRequest>();
    return request.user;
  }

  private validateUserRole(
    user: AuthenticatedRequest['user'],
    requiredRoles: string[],
  ): boolean {
    if (!user?.role) {
      throw new ForbiddenException('Access denied: No role assigned');
    }
    // Superadmin bypasses all role checks — full system access
    if (user.role === 'superadmin') {
      return true;
    }
    if (!requiredRoles.includes(user.role)) {
      throw new ForbiddenException('Access denied: Insufficient permissions');
    }
    return true;
  }
}
