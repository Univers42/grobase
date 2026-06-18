/**
 * JWT Strategy
 * Validates JWT tokens for protected routes
 */
import { Injectable, UnauthorizedException } from '@nestjs/common';
import { PassportStrategy } from '@nestjs/passport';
import { ExtractJwt, Strategy } from 'passport-jwt';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../../prisma';
import type { JwtPayload } from '../../common';
import { AUTH_COOKIE_NAME } from '../auth-cookie.constants';

function extractJwtFromCookie(
  request: { headers?: { cookie?: string } } | null,
): string | null {
  const cookieHeader = request?.headers?.cookie;
  if (!cookieHeader) return null;

  const cookies = cookieHeader.split(';');
  for (const cookie of cookies) {
    const [rawName, ...rawValueParts] = cookie.trim().split('=');
    if (rawName !== AUTH_COOKIE_NAME) continue;

    const rawValue = rawValueParts.join('=');
    if (!rawValue) return null;

    try {
      return decodeURIComponent(rawValue);
    } catch {
      return rawValue;
    }
  }

  return null;
}

@Injectable()
export class JwtStrategy extends PassportStrategy(Strategy) {
  constructor(
    config: ConfigService,
    private readonly prisma: PrismaService,
  ) {
    super({
      jwtFromRequest: ExtractJwt.fromExtractors([
        ExtractJwt.fromAuthHeaderAsBearerToken(),
        extractJwtFromCookie,
      ]),
      ignoreExpiration: false,
      secretOrKey:
        config.get<string>('JWT_SECRET') ||
        'fallback-secret-change-in-production',
    });
  }

  /**
   * Validate JWT payload and return user info
   */
  async validate(payload: JwtPayload): Promise<JwtPayload> {
    const user = await this.prisma.user.findUnique({
      where: { id: payload.sub },
      select: { id: true, is_active: true },
    });

    if (!user?.is_active) {
      throw new UnauthorizedException('User not found or inactive');
    }

    return payload;
  }
}
