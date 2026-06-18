/**
 * Token Service
 * JWT token generation and password reset tokens
 */
import { Injectable, UnauthorizedException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { PrismaService } from '../prisma';
import { randomBytes } from 'node:crypto';

interface TokenPayload {
  sub: number;
  email: string;
  role: string;
}

@Injectable()
export class TokenService {
  constructor(
    private readonly jwtService: JwtService,
    private readonly prisma: PrismaService,
  ) {}

  /**
   * Generate JWT access token
   */
  generateAccessToken(payload: TokenPayload): string {
    return this.jwtService.sign(payload);
  }

  /**
   * Verify and decode JWT token
   */
  verifyToken(token: string): TokenPayload {
    return this.jwtService.verify<TokenPayload>(token);
  }

  /**
   * Create password reset token
   */
  async createPasswordResetToken(userId: number): Promise<string> {
    await this.invalidateExistingTokens(userId);
    const token = randomBytes(32).toString('hex');
    const expiresAt = new Date(Date.now() + 3600000); // 1 hour

    await this.prisma.passwordResetToken.create({
      data: { user_id: userId, token, expires_at: expiresAt },
    });

    return token;
  }

  /**
   * Validate password reset token and return user ID
   */
  async validatePasswordResetToken(token: string): Promise<number> {
    const record = await this.prisma.passwordResetToken.findUnique({
      where: { token },
    });

    if (!record || record.used || new Date() > record.expires_at) {
      throw new UnauthorizedException('Invalid or expired reset token');
    }

    await this.prisma.passwordResetToken.update({
      where: { id: record.id },
      data: { used: true },
    });

    return record.user_id;
  }

  private async invalidateExistingTokens(userId: number): Promise<void> {
    await this.prisma.passwordResetToken.updateMany({
      where: { user_id: userId, used: false },
      data: { used: true },
    });
  }
}
