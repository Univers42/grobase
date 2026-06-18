/**
 * Newsletter Service
 *
 * Handles newsletter subscriptions (anonymous + registered users),
 * confirmation emails, unsubscribe, and bulk promotion sends.
 *
 * Read-only access to Promotion table for email content.
 */
import {
  Injectable,
  Logger,
  ConflictException,
  NotFoundException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import { MailService } from '../mail';
import { ConfigService } from '@nestjs/config';
import { SubscribeNewsletterDto } from './dto/newsletter.dto';
import { randomBytes } from 'node:crypto';

@Injectable()
export class NewsletterService {
  private readonly logger = new Logger(NewsletterService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly mailService: MailService,
    private readonly config: ConfigService,
  ) {}

  /**
   * Subscribe an email to the newsletter (anonymous or registered user).
   */
  async subscribe(dto: SubscribeNewsletterDto, userId?: number) {
    const existing = await this.prisma.newsletterSubscriber.findUnique({
      where: { email: dto.email },
    });

    if (existing) {
      if (existing.is_active) {
        throw new ConflictException(
          'Cet email est déjà inscrit à la newsletter.',
        );
      }
      // Re-activate a previously unsubscribed email
      const token = this.generateToken();
      await this.prisma.newsletterSubscriber.update({
        where: { id: existing.id },
        data: {
          is_active: true,
          unsubscribed_at: null,
          token,
          first_name: dto.firstName || existing.first_name,
          user_id: userId || existing.user_id,
        },
      });
      await this.sendConfirmationEmail(
        dto.email,
        dto.firstName || existing.first_name || '',
        token,
      );
      return {
        message:
          'Réinscription effectuée ! Vérifiez votre email pour confirmer.',
      };
    }

    const token = this.generateToken();
    await this.prisma.newsletterSubscriber.create({
      data: {
        email: dto.email,
        first_name: dto.firstName,
        user_id: userId,
        token,
        is_active: true,
      },
    });

    // If the user is registered, update their newsletter_consent
    if (userId) {
      await this.prisma.user
        .update({
          where: { id: userId },
          data: {
            newsletter_consent: true,
            newsletter_consent_date: new Date(),
          },
        })
        .catch(() => {
          /* ignore if user doesn't exist */
        });
    }

    await this.sendConfirmationEmail(dto.email, dto.firstName || '', token);
    return {
      message:
        'Inscription à la newsletter réussie ! Vérifiez votre email pour confirmer.',
    };
  }

  /**
   * Confirm a subscription via token.
   */
  async confirm(token: string) {
    const sub = await this.prisma.newsletterSubscriber.findUnique({
      where: { token },
    });
    if (!sub) throw new NotFoundException('Token invalide ou expiré.');

    await this.prisma.newsletterSubscriber.update({
      where: { id: sub.id },
      data: { confirmed_at: new Date(), is_active: true },
    });

    return {
      message:
        'Inscription confirmée ! Vous recevrez nos prochaines actualités.',
    };
  }

  /**
   * Unsubscribe via token.
   */
  async unsubscribe(token: string) {
    const sub = await this.prisma.newsletterSubscriber.findUnique({
      where: { token },
    });
    if (!sub) throw new NotFoundException('Token invalide.');

    await this.prisma.newsletterSubscriber.update({
      where: { id: sub.id },
      data: { is_active: false, unsubscribed_at: new Date() },
    });

    // Update user newsletter_consent if linked
    if (sub.user_id) {
      await this.prisma.user
        .update({
          where: { id: sub.user_id },
          data: { newsletter_consent: false },
        })
        .catch(() => {});
    }

    return {
      message: 'Désinscription effectuée. Vous ne recevrez plus nos emails.',
    };
  }

  /**
   * Get all active subscribers (admin).
   */
  async getSubscribers() {
    return this.prisma.newsletterSubscriber.findMany({
      where: { is_active: true },
      orderBy: { created_at: 'desc' },
    });
  }

  /**
   * Get subscriber count stats (admin).
   */
  async getStats() {
    const [total, active, confirmed] = await Promise.all([
      this.prisma.newsletterSubscriber.count(),
      this.prisma.newsletterSubscriber.count({ where: { is_active: true } }),
      this.prisma.newsletterSubscriber.count({
        where: { confirmed_at: { not: null }, is_active: true },
      }),
    ]);
    return { total, active, confirmed };
  }

  /**
   * Send a promotion newsletter to ALL active subscribers.
   * Called automatically when a promotion is created/updated.
   */
  async sendPromotionNewsletter(promotionId: number, sentBy?: number) {
    const promotion = await this.prisma.promotion.findUnique({
      where: { id: promotionId },
      include: {
        Discount: { select: { code: true, type: true, value: true } },
      },
    });
    if (!promotion) throw new NotFoundException('Promotion introuvable.');

    const subscribers = await this.prisma.newsletterSubscriber.findMany({
      where: { is_active: true, confirmed_at: { not: null } },
    });

    if (subscribers.length === 0) {
      this.logger.warn('No confirmed newsletter subscribers — skipping send.');
      return { sent: 0 };
    }

    this.logger.log(
      `Sending promotion "${promotion.title}" to ${subscribers.length} subscribers...`,
    );

    let sentCount = 0;
    const frontendUrl = this.config.get<string>(
      'FRONTEND_URL',
      'http://localhost:5173',
    );

    // Send emails in parallel batches of 5
    const batches = this.chunk(subscribers, 5);
    for (const batch of batches) {
      await Promise.allSettled(
        batch.map(async (sub) => {
          const html = this.buildPromotionEmail(promotion, sub, frontendUrl);
          const success = await this.mailService.send({
            to: sub.email,
            subject: `🍽️ ${promotion.title} — Vite & Gourmand`,
            html,
          });
          if (success) sentCount++;
        }),
      );
    }

    // Log the send
    await this.prisma.newsletterSendLog.create({
      data: {
        promotion_id: promotionId,
        recipients_count: sentCount,
        sent_by: sentBy,
        status: getNewsletterSendStatus(sentCount, subscribers.length),
      },
    });

    this.logger.log(
      `Newsletter sent: ${sentCount}/${subscribers.length} delivered.`,
    );
    return { sent: sentCount, total: subscribers.length };
  }

  /**
   * Get send history (admin).
   */
  async getSendHistory() {
    const logs = await this.prisma.newsletterSendLog.findMany({
      orderBy: { sent_at: 'desc' },
      take: 50,
    });
    // Manually fetch promotion info for each log
    const promoIds = [...new Set(logs.map((l) => l.promotion_id))];
    const promos = await this.prisma.promotion.findMany({
      where: { id: { in: promoIds } },
      select: { id: true, title: true, type: true },
    });
    const promoMap = new Map(promos.map((p) => [p.id, p]));
    return logs.map((log) => ({
      ...log,
      promotion: promoMap.get(log.promotion_id) || null,
    }));
  }

  /* ═══════════════════════════════════════════════════════════
     Private helpers
     ═══════════════════════════════════════════════════════════ */

  private generateToken(): string {
    return `nl_${randomBytes(24).toString('hex')}`;
  }

  private chunk<T>(arr: T[], size: number): T[][] {
    const chunks: T[][] = [];
    for (let i = 0; i < arr.length; i += size) {
      chunks.push(arr.slice(i, i + size));
    }
    return chunks;
  }

  private async sendConfirmationEmail(
    email: string,
    firstName: string,
    token: string,
  ) {
    const frontendUrl = this.config.get<string>(
      'FRONTEND_URL',
      'http://localhost:5173',
    );
    const confirmUrl = `${frontendUrl}/?newsletter=confirm&token=${token}`;
    const unsubUrl = `${frontendUrl}/?newsletter=unsubscribe&token=${token}`;

    await this.mailService.send({
      to: email,
      subject: '📬 Confirmez votre inscription — Vite & Gourmand',
      html: `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #faf7f5; margin: 0; padding: 0; }
    .container { max-width: 600px; margin: 0 auto; background: #ffffff; }
    .header { background: linear-gradient(135deg, #722F37 0%, #8a3a44 100%); padding: 30px; text-align: center; }
    .header h1 { color: #ffffff; margin: 0; font-size: 24px; }
    .content { padding: 40px 30px; color: #333; }
    .content h2 { color: #722F37; margin: 0 0 20px; }
    .content p { line-height: 1.6; margin: 0 0 16px; }
    .btn { display: inline-block; background: #722F37; color: #ffffff !important; padding: 14px 32px; text-decoration: none; border-radius: 8px; font-weight: 600; margin: 20px 0; }
    .footer { background: #f5f0ed; padding: 20px 30px; text-align: center; font-size: 12px; color: #888; }
    .unsub { color: #999; font-size: 11px; }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>📬 Newsletter Vite & Gourmand</h1>
    </div>
    <div class="content">
      <h2>Bienvenue ${firstName || ''} ! 🎉</h2>
      <p>Merci de votre inscription à notre newsletter !</p>
      <p>Pour confirmer votre adresse email et recevoir nos actualités, promotions et nouveaux menus, cliquez sur le bouton ci-dessous :</p>
      <a href="${confirmUrl}" class="btn">✅ Confirmer mon inscription</a>
      <p>Vous recevrez ensuite nos dernières offres et actualités gourmandes directement dans votre boîte mail.</p>
    </div>
    <div class="footer">
      <p>© ${new Date().getFullYear()} Vite & Gourmand — Traiteur d'exception</p>
      <p class="unsub">Si vous n'avez pas demandé cette inscription, <a href="${unsubUrl}">cliquez ici pour vous désinscrire</a>.</p>
    </div>
  </div>
</body>
</html>`,
    });
  }

  private buildPromotionEmail(
    promotion: {
      title: string;
      description: string | null;
      short_text: string | null;
      badge_text: string | null;
      bg_color: string | null;
      text_color: string | null;
      link_url: string | null;
      link_label: string | null;
      image_url: string | null;
      Discount?: { code: string; type: string; value: unknown } | null;
    },
    subscriber: { email: string; first_name: string | null; token: string },
    frontendUrl: string,
  ): string {
    const unsubUrl = `${frontendUrl}/?newsletter=unsubscribe&token=${subscriber.token}`;
    const bgColor = promotion.bg_color || '#722F37';
    const textColor = promotion.text_color || '#FFFFFF';
    const linkUrl = promotion.link_url
      ? `${frontendUrl}${promotion.link_url}`
      : frontendUrl;
    const discountCode = promotion.Discount?.code;

    return `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #faf7f5; margin: 0; padding: 0; }
    .container { max-width: 600px; margin: 0 auto; background: #ffffff; }
    .banner { background: ${bgColor}; color: ${textColor}; padding: 40px 30px; text-align: center; }
    .banner h1 { margin: 0 0 10px; font-size: 28px; }
    .banner .badge { display: inline-block; background: rgba(255,255,255,0.2); padding: 6px 16px; border-radius: 20px; font-size: 14px; font-weight: 600; margin-bottom: 15px; }
    .banner .subtitle { font-size: 16px; opacity: 0.9; }
    .content { padding: 30px; color: #333; }
    .content p { line-height: 1.6; margin: 0 0 16px; }
    .code-box { background: #f5f0ed; border: 2px dashed #D4AF37; padding: 15px; border-radius: 8px; text-align: center; margin: 20px 0; }
    .code-box .code { font-size: 24px; font-weight: 700; color: #722F37; letter-spacing: 3px; }
    .code-box p { margin: 8px 0 0; font-size: 13px; color: #666; }
    .btn { display: inline-block; background: #722F37; color: #ffffff !important; padding: 14px 32px; text-decoration: none; border-radius: 8px; font-weight: 600; }
    .cta { text-align: center; margin: 25px 0; }
    ${promotion.image_url ? '.promo-img { width: 100%; height: auto; border-radius: 8px; margin: 20px 0; }' : ''}
    .footer { background: #f5f0ed; padding: 20px 30px; text-align: center; font-size: 12px; color: #888; }
    .unsub { color: #999; font-size: 11px; margin-top: 10px; }
    .unsub a { color: #999; }
  </style>
</head>
<body>
  <div class="container">
    <div class="banner">
      ${promotion.badge_text ? `<div class="badge">${promotion.badge_text}</div>` : ''}
      <h1>${promotion.title}</h1>
      ${promotion.short_text ? `<div class="subtitle">${promotion.short_text}</div>` : ''}
    </div>
    <div class="content">
      <p>Bonjour ${subscriber.first_name || ''} 👋</p>
      ${promotion.description ? `<p>${promotion.description}</p>` : ''}
      ${promotion.image_url ? `<img src="${promotion.image_url}" alt="${promotion.title}" class="promo-img" />` : ''}
      ${
        discountCode
          ? `
      <div class="code-box">
        <div class="code">${discountCode}</div>
        <p>Utilisez ce code lors de votre commande</p>
      </div>
      `
          : ''
      }
      <div class="cta">
        <a href="${linkUrl}" class="btn">${promotion.link_label || "Découvrir l'offre"} →</a>
      </div>
    </div>
    <div class="footer">
      <p>© ${new Date().getFullYear()} Vite & Gourmand — Traiteur d'exception à Bordeaux</p>
      <p class="unsub">Vous recevez cet email car vous êtes inscrit(e) à notre newsletter.<br/><a href="${unsubUrl}">Se désinscrire</a></p>
    </div>
  </div>
</body>
</html>`;
  }
}

function getNewsletterSendStatus(
  sentCount: number,
  subscriberCount: number,
): 'sent' | 'partial' | 'failed' {
  if (sentCount === subscriberCount) return 'sent';
  if (sentCount > 0) return 'partial';
  return 'failed';
}
