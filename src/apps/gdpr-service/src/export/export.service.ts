/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   export.service.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

/**
 * Data export service — delegates to a webhook so the consuming app
 * can assemble its own domain-specific user data export.
 * The GDPR service wraps the result with metadata.
 */
@Injectable()
export class ExportService {
  private readonly logger = new Logger(ExportService.name);

  constructor(private readonly config: ConfigService) {}

  async exportUserData(userId: string): Promise<Record<string, unknown>> {
    const url = this.config.get<string>('GDPR_EXPORT_WEBHOOK_URL');

    let appData: Record<string, unknown> = {};

    if (url) {
      try {
        const res = await fetch(`${url}?userId=${encodeURIComponent(userId)}`, {
          method: 'GET',
          headers: { 'Content-Type': 'application/json' },
        });
        if (res.ok) {
          appData = (await res.json()) as Record<string, unknown>;
        } else {
          this.logger.warn(`Export webhook returned ${res.status}`);
        }
      } catch (err) {
        this.logger.error(`Export webhook failed: ${(err as Error).message}`);
      }
    } else {
      this.logger.warn('GDPR_EXPORT_WEBHOOK_URL not configured — returning empty export');
    }

    return {
      exportedAt: new Date().toISOString(),
      formatVersion: '1.0',
      userId,
      data: appData,
    };
  }
}
