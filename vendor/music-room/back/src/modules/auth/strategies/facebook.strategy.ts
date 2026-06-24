import { Injectable } from '@nestjs/common';
import { PassportStrategy } from '@nestjs/passport';
import { Strategy, Profile } from 'passport-facebook';
import { ConfigService } from '@nestjs/config';
import { AuthService } from '../auth.service';

@Injectable()
export class FacebookStrategy extends PassportStrategy(Strategy, 'facebook') {
  constructor(
    private readonly configService: ConfigService,
    private readonly authService: AuthService,
  ) {
    super({
      clientID: configService.get<string>('FACEBOOK_APP_ID', ''),
      clientSecret: configService.get<string>('FACEBOOK_APP_SECRET', ''),
      callbackURL: configService.get<string>('FACEBOOK_CALLBACK_URL', 'http://localhost:3000/auth/facebook/callback'),
      scope: ['email'],
      profileFields: ['id', 'emails', 'name', 'displayName', 'photos'],
    });
  }

  async validate(
    accessToken: string,
    refreshToken: string,
    profile: Profile,
    done: (err: Error | null, user?: unknown) => void,
  ): Promise<void> {
    const tokens = await this.authService.validateFacebookUser({
      facebookId: profile.id,
      email: profile.emails?.[0]?.value || '',
      displayName: profile.displayName || '',
      avatar: profile.photos?.[0]?.value,
    });
    done(null, tokens);
  }
}
