/**
 * Current User Decorator
 * Extracts authenticated user from request
 */
import { createParamDecorator, ExecutionContext } from '@nestjs/common';
import type { AuthenticatedRequest } from '../types/request.types';

/**
 * Extract current user from request
 * @param data - Optional property to extract from user
 * @example @CurrentUser() user: JwtPayload
 * @example @CurrentUser('id') userId: number
 */
export const CurrentUser = createParamDecorator(
  (data: string | undefined, ctx: ExecutionContext) => {
    const request = ctx.switchToHttp().getRequest<AuthenticatedRequest>();
    const user = request.user;

    if (!user) {
      return null;
    }

    return data ? user[data as keyof typeof user] : user;
  },
);
