import { Injectable, ExecutionContext } from '@nestjs/common';
import { AuthGuard } from '@nestjs/passport';

@Injectable()
export class GoogleAuthGuard extends AuthGuard('google') {
  handleRequest<TUser = any>(err: Error | null, user: TUser): TUser {
    if (err || !user) {
      throw err || new Error('Google authentication failed');
    }
    return user;
  }
}
