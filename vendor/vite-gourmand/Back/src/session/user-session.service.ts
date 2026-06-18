/**
 * User Session Service - Manage user's own sessions
 */
import {
  Injectable,
  NotFoundException,
  ForbiddenException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreateSessionDto } from './dto/session.dto';

@Injectable()
export class UserSessionService {
  constructor(private readonly prisma: PrismaService) {}

  /** Create a new session */
  async create(userId: number, dto: CreateSessionDto) {
    const expiresAt = new Date();
    expiresAt.setDate(expiresAt.getDate() + 7);
    return this.prisma.userSession.create({
      data: {
        user_id: userId,
        session_token: dto.token,
        user_agent: dto.device_info,
        ip_address: dto.ip_address,
        expires_at: expiresAt,
      },
    });
  }

  /** Get session by token */
  async getByToken(token: string) {
    return this.prisma.userSession.findUnique({
      where: { session_token: token },
      include: {
        User: {
          select: {
            id: true,
            email: true,
            first_name: true,
            last_name: true,
            Role: true,
          },
        },
      },
    });
  }

  /** Get all sessions for user */
  async getUserSessions(userId: number, currentToken?: string) {
    const sessions = await this.prisma.userSession.findMany({
      where: { user_id: userId },
      select: {
        id: true,
        user_agent: true,
        ip_address: true,
        created_at: true,
        expires_at: true,
        session_token: true,
      },
      orderBy: { created_at: 'desc' },
    });

    interface SessionRow {
      id: number;
      user_agent: string | null;
      ip_address: string | null;
      created_at: Date | null;
      expires_at: Date;
      session_token: string;
    }

    return sessions.map((s: SessionRow) => ({
      id: s.id,
      device_info: s.user_agent,
      ip_address: s.ip_address,
      created_at: s.created_at,
      expires_at: s.expires_at,
      is_current: currentToken ? s.session_token === currentToken : false,
    }));
  }

  /** Validate session token */
  async validate(token: string) {
    const session = await this.prisma.userSession.findUnique({
      where: { session_token: token },
    });
    if (!session) return { valid: false, reason: 'Session not found' };
    if (session.expires_at < new Date()) {
      await this.prisma.userSession.delete({ where: { id: session.id } });
      return { valid: false, reason: 'Session expired' };
    }
    return { valid: true, userId: session.user_id };
  }

  /** Revoke specific session */
  async revoke(sessionId: number, userId: number) {
    const session = await this.prisma.userSession.findUnique({
      where: { id: sessionId },
    });
    if (!session) throw new NotFoundException('Session not found');
    if (session.user_id !== userId)
      throw new ForbiddenException("Cannot revoke other user's sessions");
    return this.prisma.userSession.delete({ where: { id: sessionId } });
  }

  /** Revoke all sessions for user (except current) */
  async revokeAll(userId: number, exceptToken?: string) {
    const where: { user_id: number; session_token?: { not: string } } = {
      user_id: userId,
    };
    if (exceptToken) where.session_token = { not: exceptToken };
    return this.prisma.userSession.deleteMany({ where });
  }

  /** Extend session expiration */
  async extend(token: string, days = 7) {
    const session = await this.prisma.userSession.findUnique({
      where: { session_token: token },
    });
    if (!session) throw new NotFoundException('Session not found');
    const newExpiration = new Date();
    newExpiration.setDate(newExpiration.getDate() + days);
    return this.prisma.userSession.update({
      where: { id: session.id },
      data: { expires_at: newExpiration },
    });
  }
}
