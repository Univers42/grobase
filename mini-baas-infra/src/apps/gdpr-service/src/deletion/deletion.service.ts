/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   deletion.service.ts                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:10 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  Injectable,
  Logger,
  NotFoundException,
  ConflictException,
  BadRequestException,
  OnModuleInit,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PostgresService } from '@mini-baas/database';

@Injectable()
export class DeletionService implements OnModuleInit {
  private readonly logger = new Logger(DeletionService.name);

  constructor(
    private readonly pg: PostgresService,
    private readonly config: ConfigService,
  ) {}

  async onModuleInit(): Promise<void> {
    await this.pg.adminQuery(`
      CREATE SCHEMA IF NOT EXISTS gdpr;

      CREATE TABLE IF NOT EXISTS gdpr.data_deletion_request (
        id            BIGSERIAL PRIMARY KEY,
        user_id       TEXT NOT NULL,
        reason        TEXT,
        status        TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'in_progress', 'completed', 'rejected')),
        admin_note    TEXT,
        processed_by  TEXT,
        requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
        processed_at  TIMESTAMPTZ
      );

      ALTER TABLE gdpr.data_deletion_request ENABLE ROW LEVEL SECURITY;

      DO $$ BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_policies
          WHERE schemaname = 'gdpr' AND tablename = 'data_deletion_request' AND policyname = 'deletion_owner'
        ) THEN
          CREATE POLICY deletion_owner ON gdpr.data_deletion_request
            FOR ALL USING (user_id = auth.current_user_id()::text);
        END IF;
      END $$;
    `);
    this.logger.log('GDPR deletion request table ensured');
  }

  /** Create a data deletion request */
  async createRequest(userId: string, reason?: string) {
    // Check for existing pending/in_progress request
    const existing = await this.pg.tenantQuery(
      userId,
      `SELECT id FROM gdpr.data_deletion_request
       WHERE user_id = $1 AND status IN ('pending', 'in_progress') LIMIT 1`,
      [userId],
    );
    if (existing.length > 0) {
      throw new ConflictException('A pending data deletion request already exists');
    }

    const rows = await this.pg.tenantQuery(
      userId,
      `INSERT INTO gdpr.data_deletion_request (user_id, reason) VALUES ($1, $2) RETURNING *`,
      [userId, reason ?? null],
    );
    return rows[0];
  }

  /** Get user's most recent deletion request */
  async getMyRequest(userId: string) {
    const rows = await this.pg.tenantQuery(
      userId,
      `SELECT * FROM gdpr.data_deletion_request WHERE user_id = $1 ORDER BY requested_at DESC LIMIT 1`,
      [userId],
    );
    return rows[0] ?? null;
  }

  /** Cancel a pending deletion request */
  async cancelRequest(userId: string) {
    const rows = await this.pg.tenantQuery(
      userId,
      `DELETE FROM gdpr.data_deletion_request WHERE user_id = $1 AND status = 'pending' RETURNING *`,
      [userId],
    );
    if (rows.length === 0) throw new NotFoundException('No pending deletion request found');
    return rows[0];
  }

  /** List all deletion requests (admin) */
  async getAllRequests(status?: string) {
    if (status) {
      return this.pg.adminQuery(
        `SELECT * FROM gdpr.data_deletion_request WHERE status = $1 ORDER BY requested_at DESC`,
        [status],
      );
    }
    return this.pg.adminQuery(
      `SELECT * FROM gdpr.data_deletion_request ORDER BY requested_at DESC`,
    );
  }

  /** Process a deletion request (admin) */
  async processRequest(
    requestId: string,
    status: 'in_progress' | 'completed' | 'rejected',
    adminId: string,
    adminNote?: string,
  ) {
    const rows = await this.pg.adminQuery(
      `SELECT * FROM gdpr.data_deletion_request WHERE id = $1`,
      [requestId],
    );
    if (rows.length === 0) throw new NotFoundException('Deletion request not found');
    const req = rows[0] as { status: string; user_id: string };
    if (req.status === 'completed') {
      throw new BadRequestException('Request already completed');
    }

    // If completing, call the webhook so the consuming app can do its own cleanup
    if (status === 'completed') {
      await this.callDeletionWebhook(req.user_id);
    }

    const updated = await this.pg.adminQuery(
      `UPDATE gdpr.data_deletion_request
       SET status = $2, processed_by = $3, processed_at = now(), admin_note = $4
       WHERE id = $1 RETURNING *`,
      [requestId, status, adminId, adminNote ?? null],
    );
    return updated[0];
  }

  /**
   * Fire a webhook to the consuming application so it can handle
   * domain-specific data cleanup (anonymize tables, delete records, etc).
   * This keeps the GDPR service schema-agnostic.
   */
  private async callDeletionWebhook(userId: string): Promise<void> {
    const url = this.config.get<string>('GDPR_DELETION_WEBHOOK_URL');
    if (!url) {
      this.logger.warn('GDPR_DELETION_WEBHOOK_URL not configured — skipping deletion callback');
      return;
    }

    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ userId, action: 'delete_user_data' }),
      });
      if (!res.ok) {
        this.logger.error(`Deletion webhook returned ${res.status}: ${await res.text()}`);
      }
    } catch (err) {
      this.logger.error(`Deletion webhook failed: ${(err as Error).message}`);
    }
  }
}
