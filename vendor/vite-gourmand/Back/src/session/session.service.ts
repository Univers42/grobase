/**
 * Session Service - Facade for user and admin session operations
 */
import { Injectable } from '@nestjs/common';
import { UserSessionService } from './user-session.service';
import { AdminSessionService } from './admin-session.service';
import { CreateSessionDto } from './dto/session.dto';

@Injectable()
export class SessionService {
  constructor(
    private readonly userSessionService: UserSessionService,
    private readonly adminSessionService: AdminSessionService,
  ) {}

  // User operations - delegate to UserSessionService
  createSession(userId: number, dto: CreateSessionDto) {
    return this.userSessionService.create(userId, dto);
  }
  getSessionByToken(token: string) {
    return this.userSessionService.getByToken(token);
  }
  getUserSessions(userId: number, currentToken?: string) {
    return this.userSessionService.getUserSessions(userId, currentToken);
  }
  validateSession(token: string) {
    return this.userSessionService.validate(token);
  }
  revokeSession(sessionId: number, userId: number) {
    return this.userSessionService.revoke(sessionId, userId);
  }
  revokeAllSessions(userId: number, exceptToken?: string) {
    return this.userSessionService.revokeAll(userId, exceptToken);
  }
  extendSession(token: string, days?: number) {
    return this.userSessionService.extend(token, days);
  }

  // Admin operations - delegate to AdminSessionService
  getActiveSessions(userId: number) {
    return this.adminSessionService.getActiveSessions(userId);
  }
  cleanupExpiredSessions() {
    return this.adminSessionService.cleanupExpired();
  }
  getSessionStats() {
    return this.adminSessionService.getStats();
  }
  getAllSessions(options: { userId?: number; active?: boolean }) {
    return this.adminSessionService.getAll(options);
  }
  adminRevokeSession(sessionId: number) {
    return this.adminSessionService.forceRevoke(sessionId);
  }
  adminRevokeAllUserSessions(userId: number) {
    return this.adminSessionService.forceRevokeAll(userId);
  }
}
