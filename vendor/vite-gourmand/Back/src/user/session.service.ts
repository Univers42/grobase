/**
 * Session Service
 * User session management
 */
import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { randomBytes } from 'node:crypto';

const SESSION_DURATION_DAYS = 30;

@Injectable()
export class SessionService {
  constructor(private readonly prisma: PrismaService) {}

  async createSession(userId: number, ip?: string, userAgent?: string) {
    const sessionToken = randomBytes(64).toString('hex');
    const expiresAt = this.getExpirationDate();

    return this.prisma.userSession.create({
      data: {
        user_id: userId,
        session_token: sessionToken,
        ip_address: ip,
        user_agent: userAgent,
        expires_at: expiresAt,
      },
    });
  }

  async findByToken(token: string) {
    return this.prisma.userSession.findUnique({
      where: { session_token: token },
      include: { User: true },
    });
  }

  async invalidateSession(token: string) {
    await this.prisma.userSession.update({
      where: { session_token: token },
      data: { is_active: false },
    });
  }

  async invalidateAllUserSessions(userId: number) {
    await this.prisma.userSession.updateMany({
      where: { user_id: userId, is_active: true },
      data: { is_active: false },
    });
  }

  async cleanupExpiredSessions() {
    await this.prisma.userSession.deleteMany({
      where: { expires_at: { lt: new Date() } },
    });
  }

  private getExpirationDate(): Date {
    const date = new Date();
    date.setDate(date.getDate() + SESSION_DURATION_DAYS);
    return date;
  }
}
