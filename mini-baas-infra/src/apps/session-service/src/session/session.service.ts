/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   session.service.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:11 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger, ForbiddenException, NotFoundException, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PostgresService } from '@mini-baas/database';

@Injectable()
export class SessionService implements OnModuleInit {
  private readonly logger = new Logger(SessionService.name);
  private ttlDays!: number;

  constructor(
    private readonly pg: PostgresService,
    private readonly config: ConfigService,
  ) {}

  async onModuleInit(): Promise<void> {
    this.ttlDays = this.config.get<number>('SESSION_TTL_DAYS', 7);

    // Bootstrap schema and table
    await this.pg.adminQuery(`
      CREATE SCHEMA IF NOT EXISTS session;

      CREATE TABLE IF NOT EXISTS session.user_sessions (
        id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        user_id       TEXT NOT NULL,
        session_token TEXT NOT NULL UNIQUE,
        device_info   TEXT,
        ip_address    TEXT,
        expires_at    TIMESTAMPTZ NOT NULL,
        created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
      );

      CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON session.user_sessions(user_id);
      CREATE INDEX IF NOT EXISTS idx_sessions_token ON session.user_sessions(session_token);
      CREATE INDEX IF NOT EXISTS idx_sessions_expires ON session.user_sessions(expires_at);

      -- RLS
      ALTER TABLE session.user_sessions ENABLE ROW LEVEL SECURITY;

      DO $$ BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_policies WHERE tablename = 'user_sessions' AND schemaname = 'session' AND policyname = 'user_own_sessions'
        ) THEN
          CREATE POLICY user_own_sessions ON session.user_sessions
            FOR ALL
            USING (user_id = auth.current_user_id()::text);
        END IF;
      END $$;
    `);

    this.logger.log('Session schema and tables initialized');
  }

  /* ─────── User-scoped operations ─────── */

  async create(
    userId: string,
    token: string,
    deviceInfo?: string,
    ipAddress?: string,
  ) {
    const expiresAt = new Date();
    expiresAt.setDate(expiresAt.getDate() + this.ttlDays);

    const result = await this.pg.adminQuery(
      `INSERT INTO session.user_sessions (user_id, session_token, device_info, ip_address, expires_at)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING id, user_id, session_token, device_info, ip_address, expires_at, created_at`,
      [userId, token, deviceInfo ?? null, ipAddress ?? null, expiresAt.toISOString()],
    );
    return result[0];
  }

  async getByToken(token: string) {
    const result = await this.pg.adminQuery(
      `SELECT * FROM session.user_sessions WHERE session_token = $1`,
      [token],
    );
    return result[0] ?? null;
  }

  async getUserSessions(userId: string, currentToken?: string) {
    const result = await this.pg.tenantQuery(
      userId,
      `SELECT id, session_token, device_info, ip_address, expires_at, created_at, updated_at
       FROM session.user_sessions
       ORDER BY created_at DESC`,
    );

    return result.map((row: Record<string, unknown>) => ({
      ...row,
      isCurrent: currentToken ? row['session_token'] === currentToken : false,
    }));
  }

  async validate(token: string): Promise<{ valid: boolean; session?: Record<string, unknown> }> {
    const session = await this.getByToken(token);
    if (!session) return { valid: false };

    if (new Date(session['expires_at'] as string) < new Date()) {
      // Auto-delete expired session
      await this.pg.adminQuery(
        `DELETE FROM session.user_sessions WHERE id = $1`,
        [session['id']],
      );
      return { valid: false };
    }

    return { valid: true, session };
  }

  async revoke(sessionId: string, userId: string) {
    // Verify ownership
    const result = await this.pg.adminQuery(
      `SELECT user_id FROM session.user_sessions WHERE id = $1`,
      [sessionId],
    );
    if (!result[0]) throw new NotFoundException('Session not found');
    if (result[0]['user_id'] !== userId) throw new ForbiddenException('Not your session');

    await this.pg.adminQuery(
      `DELETE FROM session.user_sessions WHERE id = $1`,
      [sessionId],
    );
    return { revoked: true };
  }

  async revokeAll(userId: string, exceptToken?: string) {
    let query = `DELETE FROM session.user_sessions WHERE user_id = $1 RETURNING id`;
    const params: string[] = [userId];

    if (exceptToken) {
      query += ` AND session_token != $2`;
      params.push(exceptToken);
    }

    const result = await this.pg.adminQuery(query, params);
    return { revoked: result.length };
  }

  async extend(token: string, days?: number) {
    const ttl = days ?? this.ttlDays;
    const result = await this.pg.adminQuery(
      `UPDATE session.user_sessions
       SET expires_at = NOW() + INTERVAL '1 day' * $2,
           updated_at = NOW()
       WHERE session_token = $1
       RETURNING id, expires_at`,
      [token, ttl],
    );
    if (!result[0]) throw new NotFoundException('Session not found');
    return result[0];
  }

  /* ─────── Admin operations ─────── */

  async getActiveSessions(userId?: string) {
    let query = `SELECT * FROM session.user_sessions WHERE expires_at > NOW()`;
    const params: string[] = [];

    if (userId) {
      query += ` AND user_id = $1`;
      params.push(userId);
    }
    query += ` ORDER BY created_at DESC`;

    const result = await this.pg.adminQuery(query, params);
    return result;
  }

  async cleanupExpired() {
    const result = await this.pg.adminQuery(
      `DELETE FROM session.user_sessions WHERE expires_at < NOW() RETURNING id`,
    );
    return { deletedCount: result.length };
  }

  async getStats() {
    const result = await this.pg.adminQuery(`
      SELECT
        COUNT(*) AS total,
        COUNT(*) FILTER (WHERE expires_at > NOW()) AS active,
        COUNT(*) FILTER (WHERE expires_at <= NOW()) AS expired,
        COUNT(DISTINCT user_id) FILTER (WHERE expires_at > NOW()) AS active_users
      FROM session.user_sessions
    `);
    return result[0];
  }

  async adminForceRevoke(sessionId: string) {
    const result = await this.pg.adminQuery(
      `DELETE FROM session.user_sessions WHERE id = $1 RETURNING id`,
      [sessionId],
    );
    if (!result[0]) throw new NotFoundException('Session not found');
    return { revoked: true };
  }

  async adminForceRevokeAll(userId: string) {
    const result = await this.pg.adminQuery(
      `DELETE FROM session.user_sessions WHERE user_id = $1 RETURNING id`,
      [userId],
    );
    return { revoked: result.length };
  }
}
