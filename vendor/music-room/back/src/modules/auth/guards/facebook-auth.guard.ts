import { Injectable } from '@nestjs/common';
import { AuthGuard } from '@nestjs/passport';

@Injectable()
export class FacebookAuthGuard extends AuthGuard('facebook') {
  handleRequest<TUser = any>(err: Error | null, user: TUser): TUser {
    if (err || !user) {
      throw err || new Error('Facebook authentication failed');
    }
    return user;
  }
}
