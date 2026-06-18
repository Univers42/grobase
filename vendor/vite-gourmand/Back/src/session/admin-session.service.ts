/**
 * Admin Session Service - Admin session management
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';

@Injectable()
export class AdminSessionService {
  constructor(private readonly prisma: PrismaService) {}

  /** Get active sessions for user */
  async getActiveSessions(userId: number) {
    return this.prisma.userSession.findMany({
      where: { user_id: userId, expires_at: { gt: new Date() } },
      select: {
        id: true,
        user_agent: true,
        ip_address: true,
        created_at: true,
        expires_at: true,
      },
      orderBy: { created_at: 'desc' },
    });
  }

  /** Clean up expired sessions */
  async cleanupExpired() {
    const result = await this.prisma.userSession.deleteMany({
      where: { expires_at: { lt: new Date() } },
    });
    return { deletedCount: result.count };
  }

  /** Get session statistics */
  async getStats() {
    const total = await this.prisma.userSession.count();
    const active = await this.prisma.userSession.count({
      where: { expires_at: { gt: new Date() } },
    });
    const byUser = await this.prisma.userSession.groupBy({
      by: ['user_id'],
      _count: { id: true },
      where: { expires_at: { gt: new Date() } },
    });
    return {
      total,
      active,
      expired: total - active,
      usersWithActiveSessions: byUser.length,
    };
  }

  /** Get all sessions */
  async getAll(options: { userId?: number; active?: boolean }) {
    const where: {
      user_id?: number;
      expires_at?: { gt: Date } | { lt: Date };
    } = {};
    if (options.userId) where.user_id = options.userId;
    if (options.active !== undefined) {
      where.expires_at = options.active
        ? { gt: new Date() }
        : { lt: new Date() };
    }
    return this.prisma.userSession.findMany({
      where,
      include: {
        User: {
          select: { id: true, email: true, first_name: true, last_name: true },
        },
      },
      orderBy: { created_at: 'desc' },
    });
  }

  /** Force revoke session */
  async forceRevoke(sessionId: number) {
    const session = await this.prisma.userSession.findUnique({
      where: { id: sessionId },
    });
    if (!session) throw new NotFoundException('Session not found');
    return this.prisma.userSession.delete({ where: { id: sessionId } });
  }

  /** Force revoke all sessions for user */
  async forceRevokeAll(userId: number) {
    return this.prisma.userSession.deleteMany({ where: { user_id: userId } });
  }
}
