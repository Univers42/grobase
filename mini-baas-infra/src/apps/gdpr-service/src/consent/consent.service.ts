/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   consent.service.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:21 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger, NotFoundException, OnModuleInit } from '@nestjs/common';
import { PostgresService } from '@mini-baas/database';

@Injectable()
export class ConsentService implements OnModuleInit {
  private readonly logger = new Logger(ConsentService.name);

  constructor(private readonly pg: PostgresService) {}

  async onModuleInit(): Promise<void> {
    // Ensure the gdpr schema and tables exist
    await this.pg.adminQuery(`
      CREATE SCHEMA IF NOT EXISTS gdpr;

      CREATE TABLE IF NOT EXISTS gdpr.user_consent (
        id            BIGSERIAL PRIMARY KEY,
        user_id       TEXT NOT NULL,
        consent_type  TEXT NOT NULL,
        is_granted    BOOLEAN NOT NULL DEFAULT false,
        granted_at    TIMESTAMPTZ,
        revoked_at    TIMESTAMPTZ,
        created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE(user_id, consent_type)
      );

      ALTER TABLE gdpr.user_consent ENABLE ROW LEVEL SECURITY;

      DO $$ BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_policies
          WHERE schemaname = 'gdpr' AND tablename = 'user_consent' AND policyname = 'consent_owner'
        ) THEN
          CREATE POLICY consent_owner ON gdpr.user_consent
            FOR ALL USING (user_id = auth.current_user_id()::text);
        END IF;
      END $$;
    `);
    this.logger.log('GDPR consent table ensured');
  }

  /** Get all consents for a user */
  async getUserConsents(userId: string) {
    return this.pg.tenantQuery(
      userId,
      `SELECT id, user_id, consent_type, is_granted, granted_at, revoked_at, created_at
       FROM gdpr.user_consent
       WHERE user_id = $1
       ORDER BY consent_type ASC`,
      [userId],
    );
  }

  /** Get a specific consent */
  async getUserConsent(userId: string, consentType: string) {
    const rows = await this.pg.tenantQuery(
      userId,
      `SELECT * FROM gdpr.user_consent WHERE user_id = $1 AND consent_type = $2 LIMIT 1`,
      [userId, consentType],
    );
    return rows[0] ?? null;
  }

  /** Create or update a consent (upsert) */
  async setConsent(userId: string, consentType: string, consented: boolean) {
    const rows = await this.pg.tenantQuery(
      userId,
      `INSERT INTO gdpr.user_consent (user_id, consent_type, is_granted, granted_at, revoked_at)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (user_id, consent_type)
       DO UPDATE SET
         is_granted = EXCLUDED.is_granted,
         granted_at = CASE WHEN EXCLUDED.is_granted THEN now() ELSE gdpr.user_consent.granted_at END,
         revoked_at = CASE WHEN NOT EXCLUDED.is_granted THEN now() ELSE NULL END
       RETURNING *`,
      [userId, consentType, consented, consented ? new Date() : null, consented ? null : new Date()],
    );
    return rows[0];
  }

  /** Update an existing consent */
  async updateConsent(userId: string, consentType: string, consented: boolean) {
    const existing = await this.getUserConsent(userId, consentType);
    if (!existing) throw new NotFoundException('Consent not found');

    const rows = await this.pg.tenantQuery(
      userId,
      `UPDATE gdpr.user_consent
       SET is_granted = $3,
           granted_at = CASE WHEN $3 THEN now() ELSE granted_at END,
           revoked_at = CASE WHEN NOT $3 THEN now() ELSE NULL END
       WHERE user_id = $1 AND consent_type = $2
       RETURNING *`,
      [userId, consentType, consented],
    );
    return rows[0];
  }

  /** Withdraw all non-essential consents */
  async withdrawAllNonEssential(userId: string) {
    const rows = await this.pg.tenantQuery(
      userId,
      `UPDATE gdpr.user_consent
       SET is_granted = false, revoked_at = now()
       WHERE user_id = $1 AND consent_type != 'essential' AND is_granted = true
       RETURNING *`,
      [userId],
    );
    return { updated: rows.length };
  }
}
