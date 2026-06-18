/**
 * Optional Auth Guard
 * Allows both authenticated and anonymous access
 * Attaches user to request if token is valid
 */
import { Injectable, ExecutionContext } from '@nestjs/common';
import { AuthGuard } from '@nestjs/passport';

@Injectable()
export class OptionalAuthGuard extends AuthGuard('jwt') {
  /**
   * Always allow access, but attempt to authenticate
   */
  canActivate(context: ExecutionContext) {
    return super.canActivate(context);
  }

  /**
   * Don't throw on auth failure - just return null user
   */
  handleRequest<TUser>(_err: Error | null, user: TUser | false): TUser | null {
    return user || null;
  }
}
