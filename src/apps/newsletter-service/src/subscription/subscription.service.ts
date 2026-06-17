/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   subscription.service.ts                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import {
  Injectable,
  Logger,
  ConflictException,
  NotFoundException,
  OnModuleInit,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PostgresService } from '@mini-baas/database';
import { randomBytes } from 'node:crypto';

@Injectable()
export class SubscriptionService implements OnModuleInit {
  private readonly logger = new Logger(SubscriptionService.name);

  constructor(
    private readonly pg: PostgresService,
    private readonly config: ConfigService,
  ) {}

  async onModuleInit(): Promise<void> {
    await this.pg.adminQuery(`
      CREATE SCHEMA IF NOT EXISTS newsletter;

      CREATE TABLE IF NOT EXISTS newsletter.subscriber (
        id              BIGSERIAL PRIMARY KEY,
        email           TEXT NOT NULL UNIQUE,
        first_name      TEXT,
        token           TEXT NOT NULL UNIQUE,
        is_active       BOOLEAN NOT NULL DEFAULT true,
        confirmed_at    TIMESTAMPTZ,
        unsubscribed_at TIMESTAMPTZ,
        created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
      );

      CREATE TABLE IF NOT EXISTS newsletter.send_log (
        id              BIGSERIAL PRIMARY KEY,
        subject         TEXT NOT NULL,
        recipient_count INT NOT NULL DEFAULT 0,
        sent_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
        sent_by         TEXT
      );
    `);
    this.logger.log('Newsletter tables ensured');
  }

  private generateToken(): string {
    return randomBytes(32).toString('hex');
  }

  /** Subscribe an email. Reactivates if previously unsubscribed. */
  async subscribe(email: string, firstName?: string) {
    const existing = await this.pg.adminQuery<{ id: string; is_active: boolean; first_name: string }>(
      `SELECT id, is_active, first_name FROM newsletter.subscriber WHERE email = $1 LIMIT 1`,
      [email],
    );

    if (existing.length > 0) {
      const sub = existing[0];
      if (sub.is_active) {
        throw new ConflictException('This email is already subscribed');
      }
      // Reactivate
      const token = this.generateToken();
      const rows = await this.pg.adminQuery(
        `UPDATE newsletter.subscriber
         SET is_active = true, unsubscribed_at = NULL, token = $2,
             first_name = COALESCE($3, first_name)
         WHERE id = $1 RETURNING *`,
        [sub.id, token, firstName ?? null],
      );
      await this.notifyConfirmation(email, firstName ?? sub.first_name ?? '', token);
      return { reactivated: true, subscriber: rows[0] };
    }

    const token = this.generateToken();
    const rows = await this.pg.adminQuery(
      `INSERT INTO newsletter.subscriber (email, first_name, token) VALUES ($1, $2, $3) RETURNING *`,
      [email, firstName ?? null, token],
    );
    await this.notifyConfirmation(email, firstName ?? '', token);
    return { subscribed: true, subscriber: rows[0] };
  }

  /** Confirm subscription via token */
  async confirm(token: string) {
    const rows = await this.pg.adminQuery(
      `UPDATE newsletter.subscriber SET confirmed_at = now(), is_active = true
       WHERE token = $1 AND confirmed_at IS NULL RETURNING *`,
      [token],
    );
    if (rows.length === 0) throw new NotFoundException('Invalid or already-used token');
    return { confirmed: true };
  }

  /** Unsubscribe via token */
  async unsubscribe(token: string) {
    const rows = await this.pg.adminQuery(
      `UPDATE newsletter.subscriber SET is_active = false, unsubscribed_at = now()
       WHERE token = $1 RETURNING *`,
      [token],
    );
    if (rows.length === 0) throw new NotFoundException('Invalid token');
    return { unsubscribed: true };
  }

  /** List all active subscribers (admin) */
  async getSubscribers(limit = 100, offset = 0) {
    return this.pg.adminQuery(
      `SELECT id, email, first_name, confirmed_at, created_at
       FROM newsletter.subscriber WHERE is_active = true ORDER BY created_at DESC LIMIT $1 OFFSET $2`,
      [limit, offset],
    );
  }

  /** Subscriber stats (admin) */
  async getStats() {
    const rows = await this.pg.adminQuery<{ total: string; active: string; confirmed: string }>(`
      SELECT
        COUNT(*)::TEXT AS total,
        COUNT(*) FILTER (WHERE is_active = true)::TEXT AS active,
        COUNT(*) FILTER (WHERE confirmed_at IS NOT NULL AND is_active = true)::TEXT AS confirmed
      FROM newsletter.subscriber
    `);
    const r = rows[0];
    return {
      total: Number.parseInt(r.total, 10),
      active: Number.parseInt(r.active, 10),
      confirmed: Number.parseInt(r.confirmed, 10),
    };
  }

  /** Get all confirmed active subscriber emails for sending */
  async getConfirmedEmails(): Promise<{ email: string; token: string }[]> {
    return this.pg.adminQuery(
      `SELECT email, token FROM newsletter.subscriber WHERE is_active = true AND confirmed_at IS NOT NULL`,
    );
  }

  /**
   * Send confirmation email via the email-service.
   * This calls the email-service internal API.
   */
  private async notifyConfirmation(email: string, firstName: string, token: string): Promise<void> {
    const emailServiceUrl = this.config.getOrThrow<string>('EMAIL_SERVICE_URL');
    const baseUrl = this.config.getOrThrow<string>('NEWSLETTER_BASE_URL');
    const confirmUrl = `${baseUrl}/confirm/${token}`;
    const greetingName = firstName ? ` ${firstName}` : '';

    try {
      await fetch(`${emailServiceUrl}/send`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          to: email,
          subject: 'Confirm your newsletter subscription',
             html: `<p>Hello${greetingName},</p>
                 <p>Please confirm your subscription by clicking the link below:</p>
                 <p><a href="${confirmUrl}">Confirm subscription</a></p>
                 <p>If you did not subscribe, you can safely ignore this email.</p>`,
        }),
      });
    } catch (err) {
      this.logger.error(`Failed to send confirmation email: ${(err as Error).message}`);
    }
  }
}
