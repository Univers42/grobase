/**
 * Mail Service
 * Uses Titan Email SMTP for sending emails
 */
import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import * as nodemailer from 'nodemailer';

interface MailOptions {
  to: string;
  subject: string;
  html: string;
  text?: string;
}

interface MailSendInfo {
  messageId?: string;
  response?: string;
  accepted?: unknown[];
  rejected?: unknown[];
}

@Injectable()
export class MailService implements OnModuleInit {
  private readonly logger = new Logger(MailService.name);
  private transporter!: nodemailer.Transporter;
  private readonly fromEmail: string;
  private readonly isTestEnvironment: boolean;

  constructor(private readonly config: ConfigService) {
    this.isTestEnvironment =
      process.env.NODE_ENV === 'test' || this.config.get('NODE_ENV') === 'test';
    this.fromEmail = this.config.get<string>(
      'TITAN_EMAIL',
      'devfast@archicode.codes',
    );
    if (!this.isTestEnvironment) {
      this.initTransporter();
    }
  }

  async onModuleInit(): Promise<void> {
    if (this.isTestEnvironment) {
      this.logger.log('SMTP transporter disabled in test environment');
      return;
    }

    try {
      await this.transporter.verify();
      this.logger.log('SMTP transporter verified — ready to send emails');
    } catch (err) {
      this.logger.error(
        'SMTP transporter verification failed',
        (err as Error).message,
      );
    }
  }

  private initTransporter() {
    const host = this.config.get<string>('TITAN_SMTP_HOST', 'smtp.titan.email');
    const portRaw = this.config.get<string>('TITAN_SMTP_PORT', '465');
    const port = Number(portRaw);
    const user = this.config.get<string>('TITAN_EMAIL');
    const pass = this.config.get<string>('TITAN_PASSWORD');
    const secure = port === 465;

    this.logger.log(
      `Initializing mail transporter: ${host}:${port} (secure=${secure}) user=${user ? 'configured' : 'missing'}`,
    );

    this.transporter = nodemailer.createTransport({
      host,
      port,
      secure,
      auth: { user, pass },
      tls: { rejectUnauthorized: false },
      connectionTimeout: 15000,
      greetingTimeout: 15000,
      socketTimeout: 30000,
    });
  }

  /** Strip HTML tags to produce a plain-text fallback */
  private htmlToText(html: string): string {
    return html
      .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '')
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/p>/gi, '\n\n')
      .replace(/<\/div>/gi, '\n')
      .replace(/<\/h[1-6]>/gi, '\n\n')
      .replace(/<a[^>]+href="([^"]+)"[^>]*>([^<]+)<\/a>/gi, '$2 ($1)')
      .replace(/<[^>]+>/g, '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replace(/&#?\w+;/g, '')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  }

  async send(options: MailOptions): Promise<boolean> {
    if (this.isTestEnvironment) {
      this.logger.debug('Email send skipped in test environment');
      return true;
    }

    const plainText = options.text || this.htmlToText(options.html);
    try {
      const info = (await this.transporter.sendMail({
        from: `"Vite et Gourmand" <${this.fromEmail}>`,
        to: options.to,
        subject: options.subject,
        text: plainText,
        html: options.html,
        headers: {
          'X-Mailer': 'ViteGourmand/1.0',
          'X-Priority': '3',
          Precedence: 'bulk',
          'List-Unsubscribe': `<mailto:${this.fromEmail}?subject=unsubscribe>`,
          'MIME-Version': '1.0',
        },
      })) as MailSendInfo;
      this.logger.log(
        `Email sent to ${options.to} — id=${info.messageId} response="${info.response}" accepted=${JSON.stringify(info.accepted)} rejected=${JSON.stringify(info.rejected)}`,
      );
      return true;
    } catch (error) {
      this.logger.error(`Failed to send email to ${options.to}`);
      this.logger.error(error);
      return false;
    }
  }

  async sendPasswordReset(email: string, token: string): Promise<boolean> {
    const resetUrl = `${this.config.get('FRONTEND_URL')}/reset-password?token=${token}`;
    return this.send({
      to: email,
      subject: 'Reset Your Password - Vite Gourmand',
      html: this.getPasswordResetTemplate(resetUrl),
    });
  }

  async sendOrderConfirmation(
    email: string,
    orderNumber: string,
  ): Promise<boolean> {
    return this.send({
      to: email,
      subject: `Order Confirmed - ${orderNumber}`,
      html: this.getOrderConfirmationTemplate(orderNumber),
    });
  }

  private getPasswordResetTemplate(url: string): string {
    return `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #faf7f5; margin: 0; padding: 0; }
    .container { max-width: 600px; margin: 0 auto; background: #ffffff; }
    .header { background: linear-gradient(135deg, #722F37 0%, #8a3a44 100%); padding: 30px; text-align: center; }
    .header h1 { color: #ffffff; margin: 0; font-size: 28px; }
    .content { padding: 40px 30px; color: #333; }
    .content h2 { color: #722F37; margin: 0 0 20px; }
    .content p { line-height: 1.6; margin: 0 0 16px; }
    .btn { display: inline-block; background: #722F37; color: #ffffff !important; padding: 14px 32px; text-decoration: none; border-radius: 8px; font-weight: 600; margin: 20px 0; }
    .link-box { background: #f5f0ed; padding: 15px; border-radius: 8px; word-break: break-all; font-size: 12px; color: #666; margin: 20px 0; }
    .warning { background: #fff8f0; border-left: 4px solid #D4AF37; padding: 15px; margin: 20px 0; font-size: 14px; color: #666; }
    .footer { background: #f5f0ed; padding: 20px 30px; text-align: center; font-size: 12px; color: #888; }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>🔐 Réinitialisation de mot de passe</h1>
    </div>
    <div class="content">
      <h2>Bonjour,</h2>
      <p>Vous avez demandé la réinitialisation de votre mot de passe pour votre compte Vite & Gourmand.</p>
      
      <p>Cliquez sur le bouton ci-dessous pour créer un nouveau mot de passe :</p>
      <a href="${url}" class="btn">🔑 Réinitialiser mon mot de passe</a>
      
      <p>Ou copiez ce lien dans votre navigateur :</p>
      <div class="link-box">${url}</div>
      
      <div class="warning">
        <strong>⚠️ Important :</strong><br>
        Ce lien expirera dans <strong>1 heure</strong>.<br>
        Si vous n'avez pas demandé cette réinitialisation, ignorez simplement cet email.
      </div>
      
      <p style="font-size: 14px; color: #666;">
        Pour votre sécurité, ne partagez jamais ce lien avec personne.
      </p>
    </div>
    <div class="footer">
      <p>© ${new Date().getFullYear()} Vite & Gourmand - Tous droits réservés</p>
      <p>Cet email a été envoyé automatiquement, merci de ne pas y répondre.</p>
    </div>
  </div>
</body>
</html>`;
  }

  private getOrderConfirmationTemplate(orderNumber: string): string {
    return `
      <h1>Order Confirmed!</h1>
      <p>Your order <strong>${orderNumber}</strong> has been confirmed.</p>
      <p>Thank you for choosing Vite Gourmand!</p>
    `;
  }
}
