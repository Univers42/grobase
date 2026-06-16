/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   campaign.service.ts                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PostgresService } from '@mini-baas/database';
import { SubscriptionService } from '../subscription/subscription.service';

/** Split array into chunks of `size` */
function chunk<T>(arr: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < arr.length; i += size) {
    chunks.push(arr.slice(i, i + size));
  }
  return chunks;
}

@Injectable()
export class CampaignService {
  private readonly logger = new Logger(CampaignService.name);

  constructor(
    private readonly pg: PostgresService,
    private readonly config: ConfigService,
    private readonly subscriptionService: SubscriptionService,
  ) {}

  /**
   * Send a campaign email to all confirmed subscribers.
   * Batches emails in parallel groups to avoid overloading the SMTP service.
   */
  async sendCampaign(
    subject: string,
    html: string,
    text?: string,
    sentBy?: string,
  ): Promise<{ sent: number; failed: number }> {
    const subscribers = await this.subscriptionService.getConfirmedEmails();

    if (subscribers.length === 0) {
      this.logger.warn('No confirmed subscribers — skipping campaign send');
      return { sent: 0, failed: 0 };
    }

    const batchSize = this.config.get<number>('NEWSLETTER_BATCH_SIZE', 5);
    const emailServiceUrl = this.config.getOrThrow<string>('EMAIL_SERVICE_URL');
    const batches = chunk(subscribers, batchSize);

    let sent = 0;
    let failed = 0;

    for (const batch of batches) {
      const results = await Promise.allSettled(
        batch.map((sub) =>
          fetch(`${emailServiceUrl}/send`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ to: sub.email, subject, html, text }),
          }),
        ),
      );

      for (const r of results) {
        if (r.status === 'fulfilled' && r.value.ok) {
          sent++;
        } else {
          failed++;
        }
      }
    }

    // Log the send
    await this.pg.adminQuery(
      `INSERT INTO newsletter.send_log (subject, recipient_count, sent_by) VALUES ($1, $2, $3)`,
      [subject, sent, sentBy ?? null],
    );

    this.logger.log(`Campaign "${subject}" sent: ${sent} ok, ${failed} failed`);
    return { sent, failed };
  }

  /** Get campaign send history */
  async getHistory(limit = 50) {
    return this.pg.adminQuery(
      `SELECT * FROM newsletter.send_log ORDER BY sent_at DESC LIMIT $1`,
      [limit],
    );
  }
}
