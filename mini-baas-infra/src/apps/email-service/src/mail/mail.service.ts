/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mail.service.ts                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createTransport, Transporter } from 'nodemailer';
import { SendEmailDto } from './dto/send-email.dto';

@Injectable()
export class MailService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(MailService.name);
  private transporter!: Transporter;
  private from!: string;

  constructor(private readonly config: ConfigService) {}

  onModuleInit(): void {
    const host = this.config.getOrThrow<string>('SMTP_HOST');
    const port = this.config.get<number>('SMTP_PORT', 587);
    const secure = this.config.get<string>('SMTP_SECURE', 'false') === 'true';
    const user = this.config.get<string>('SMTP_USER');
    const pass = this.config.get<string>('SMTP_PASS', '');

    this.from = this.config.get<string>('EMAIL_FROM', 'noreply@mini-baas.local');

    const auth = user ? { user, pass } : undefined;

    this.transporter = createTransport({ host, port, secure, auth });

    // Non-fatal connectivity check
    this.transporter.verify().catch((err) => {
      this.logger.warn(`SMTP not reachable at startup: ${(err as Error).message}`);
    });
  }

  onModuleDestroy(): void {
    this.transporter.close();
    this.logger.log('SMTP transport closed');
  }

  async send(dto: SendEmailDto): Promise<{ messageId: string }> {
    const info = await this.transporter.sendMail({
      from: this.from,
      to: dto.to,
      subject: dto.subject,
      html: dto.html,
      text: dto.text,
    });

    this.logger.log(`Email sent: ${info.messageId} → ${dto.to}`);
    return { messageId: info.messageId };
  }

  async isHealthy(): Promise<boolean> {
    try {
      await this.transporter.verify();
      return true;
    } catch {
      return false;
    }
  }
}
