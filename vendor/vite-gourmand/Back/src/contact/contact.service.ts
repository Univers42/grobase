/**
 * Contact Service
 *
 * When a visitor submits the contact form:
 *  1. A ContactMessage row is persisted (unchanged legacy table).
 *  2. A SupportTicket is created so the team can track / manage it.
 *  3. A confirmation email is sent to the visitor with the ticket number.
 */
import { Injectable, Logger, NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../prisma';
import { MailService } from '../mail/mail.service';
import { CreateContactMessageDto } from './dto/contact.dto';

@Injectable()
export class ContactService {
  private readonly logger = new Logger(ContactService.name);
  private readonly ownerEmail: string;

  constructor(
    private readonly prisma: PrismaService,
    private readonly mail: MailService,
    private readonly config: ConfigService,
  ) {
    this.ownerEmail = this.config.get<string>(
      'TITAN_EMAIL',
      'devfast@archicode.codes',
    );
  }

  /* ── helpers ────────────────────────────────────────────── */

  private generateTicketNumber(): string {
    const d = new Date();
    const prefix = `TK${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}`;
    const random = Math.random().toString(36).substring(2, 8).toUpperCase();
    return `${prefix}-${random}`;
  }

  private mapCategory(subject: string): string {
    const s = subject.toLowerCase();
    if (
      s.includes('mariage') ||
      s.includes('anniversaire') ||
      s.includes('événement') ||
      s.includes('entreprise')
    )
      return 'order';
    if (s.includes('menu')) return 'menu';
    return 'other';
  }

  /* ── queries ────────────────────────────────────────────── */

  async findAll(options?: { limit?: number; offset?: number }) {
    return this.prisma.contactMessage.findMany({
      orderBy: { created_at: 'desc' },
      take: options?.limit || 50,
      skip: options?.offset || 0,
    });
  }

  async findById(id: number) {
    const message = await this.prisma.contactMessage.findUnique({
      where: { id },
    });
    if (!message) throw new NotFoundException('Contact message not found');
    return message;
  }

  /* ── create (public endpoint) ───────────────────────────── */

  async create(dto: CreateContactMessageDto) {
    const ticketNumber = this.generateTicketNumber();

    // 1. Persist the contact message
    const contactMessage = await this.prisma.contactMessage.create({
      data: {
        title: dto.title,
        description: dto.description,
        email: dto.email,
      },
    });

    // 2. Create a support ticket for the team
    const ticket = await this.prisma.supportTicket.create({
      data: {
        ticket_number: ticketNumber,
        category: this.mapCategory(dto.title),
        subject: dto.title,
        description:
          `[Contact — ${dto.name}] ${dto.description}\n\n—\nEmail : ${dto.email}` +
          (dto.phone ? `\nTéléphone : ${dto.phone}` : ''),
        priority: 'normal',
        status: 'open',
      },
    });

    this.logger.log(
      `Ticket ${ticketNumber} created from contact form (contact #${contactMessage.id}, ticket #${ticket.id})`,
    );

    // 3. Send confirmation email to the visitor (fire-and-forget)
    this.mail
      .send({
        to: dto.email,
        subject: `Votre demande a bien été reçue — ${ticketNumber}`,
        html: this.getTicketConfirmationTemplate(
          dto.name,
          ticketNumber,
          dto.title,
        ),
      })
      .catch((err) =>
        this.logger.error(
          `Failed to send confirmation email to ${dto.email}`,
          err,
        ),
      );

    // 4. Notify the owner / admin about the new ticket
    this.mail
      .send({
        to: this.ownerEmail,
        subject: `[Nouveau ticket] ${ticketNumber} — ${dto.title}`,
        html: this.getOwnerNotificationTemplate(dto, ticketNumber),
      })
      .then(() =>
        this.logger.log(
          `Owner notification sent to ${this.ownerEmail} for ticket ${ticketNumber}`,
        ),
      )
      .catch((err) =>
        this.logger.error(
          `Failed to send owner notification to ${this.ownerEmail}`,
          err,
        ),
      );

    return {
      ...contactMessage,
      ticket_number: ticketNumber,
    };
  }

  /* ── delete ─────────────────────────────────────────────── */

  async delete(id: number) {
    await this.findById(id);
    await this.prisma.contactMessage.delete({ where: { id } });
    return { message: 'Contact message deleted successfully' };
  }

  async count() {
    return this.prisma.contactMessage.count();
  }

  /* ── email templates ────────────────────────────────────── */

  private getOwnerNotificationTemplate(
    dto: CreateContactMessageDto,
    ticketNumber: string,
  ): string {
    const phoneRow = dto.phone
      ? `<tr><td style="padding:8px 12px;font-weight:600;color:#722F37;white-space:nowrap">Téléphone</td><td style="padding:8px 12px;color:#333">${dto.phone}</td></tr>`
      : '';

    return `
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f4f4f7; margin: 0; padding: 0; }
    .container { max-width: 600px; margin: 0 auto; background: #ffffff; }
    .header { background: linear-gradient(135deg, #722F37 0%, #8a3a44 100%); padding: 24px 30px; }
    .header h1 { color: #fff; margin: 0; font-size: 18px; }
    .header p { color: rgba(255,255,255,.7); margin: 6px 0 0; font-size: 13px; }
    .body { padding: 28px 30px; color: #333; }
    .ticket-badge { display: inline-block; background: #FFF8F0; border: 2px solid #D4AF37; border-radius: 8px; padding: 6px 16px; font-size: 18px; font-weight: 800; letter-spacing: 1px; color: #1A1A1A; margin-bottom: 18px; }
    table.info { width: 100%; border-collapse: collapse; margin: 16px 0; }
    table.info td { border-bottom: 1px solid #f0f0f0; }
    .message-box { background: #f9fafb; border-left: 4px solid #D4AF37; border-radius: 0 8px 8px 0; padding: 14px 18px; margin: 16px 0; font-size: 14px; line-height: 1.7; color: #444; white-space: pre-wrap; }
    .cta { display: inline-block; margin: 16px 0; background: #722F37; color: #fff; text-decoration: none; padding: 10px 22px; border-radius: 8px; font-weight: 600; font-size: 13px; }
    .footer { background: #f5f0ed; padding: 16px 30px; text-align: center; font-size: 11px; color: #999; }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>🎫 Nouveau ticket de contact</h1>
      <p>Un visiteur vient de soumettre le formulaire de contact</p>
    </div>
    <div class="body">
      <div class="ticket-badge">${ticketNumber}</div>

      <table class="info">
        <tr><td style="padding:8px 12px;font-weight:600;color:#722F37;white-space:nowrap">Nom</td><td style="padding:8px 12px;color:#333">${dto.name}</td></tr>
        <tr><td style="padding:8px 12px;font-weight:600;color:#722F37;white-space:nowrap">Email</td><td style="padding:8px 12px;color:#333"><a href="mailto:${dto.email}" style="color:#3B82F6">${dto.email}</a></td></tr>
        ${phoneRow}
        <tr><td style="padding:8px 12px;font-weight:600;color:#722F37;white-space:nowrap">Sujet</td><td style="padding:8px 12px;color:#333">${dto.title}</td></tr>
      </table>

      <p style="font-weight:600;color:#722F37;font-size:13px;text-transform:uppercase;letter-spacing:1px;margin:20px 0 8px">Message</p>
      <div class="message-box">${dto.description}</div>

      <p style="font-size:14px;color:#555">Connectez-vous au dashboard pour prendre en charge ce ticket :</p>
      <a href="https://vite-gourmand.fly.dev/dashboard" class="cta">Ouvrir le dashboard →</a>
    </div>
    <div class="footer">
      <p>© ${new Date().getFullYear()} Vite & Gourmand — Notification interne</p>
    </div>
  </div>
</body>
</html>`;
  }

  private getTicketConfirmationTemplate(
    name: string,
    ticketNumber: string,
    subject: string,
  ): string {
    return `
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #faf7f5; margin: 0; padding: 0; }
    .container { max-width: 600px; margin: 0 auto; background: #ffffff; }
    .header { background: linear-gradient(135deg, #722F37 0%, #8a3a44 100%); padding: 30px; text-align: center; }
    .header h1 { color: #ffffff; margin: 0; font-size: 24px; }
    .header p { color: rgba(255,255,255,0.7); margin: 8px 0 0; font-size: 14px; }
    .content { padding: 35px 30px; color: #333; }
    .content h2 { color: #722F37; margin: 0 0 15px; font-size: 20px; }
    .content p { line-height: 1.7; margin: 0 0 14px; font-size: 15px; }
    .ticket-box { background: linear-gradient(135deg, #FFF8F0, #ffffff); border: 2px solid #D4AF37; border-radius: 12px; padding: 20px; text-align: center; margin: 24px 0; }
    .ticket-box .label { color: #722F37; font-size: 12px; text-transform: uppercase; letter-spacing: 2px; font-weight: 600; margin: 0 0 8px; }
    .ticket-box .number { color: #1A1A1A; font-size: 28px; font-weight: 800; letter-spacing: 1px; margin: 0; }
    .ticket-box .subject { color: #666; font-size: 13px; margin: 10px 0 0; }
    .steps { margin: 24px 0; }
    .step { display: flex; align-items: flex-start; margin-bottom: 16px; }
    .step-num { width: 28px; height: 28px; background: #722F37; color: white; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 13px; font-weight: 700; flex-shrink: 0; margin-right: 14px; margin-top: 2px; }
    .step-text { font-size: 14px; line-height: 1.5; color: #444; }
    .step-text strong { color: #1A1A1A; }
    .info-box { background: #FFF8F0; border-left: 4px solid #D4AF37; padding: 14px 18px; margin: 20px 0; border-radius: 0 8px 8px 0; }
    .info-box p { margin: 0; font-size: 14px; color: #555; }
    .footer { background: #f5f0ed; padding: 20px 30px; text-align: center; font-size: 12px; color: #888; }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>🍽️ Vite & Gourmand</h1>
      <p>Votre demande est entre de bonnes mains</p>
    </div>
    <div class="content">
      <h2>Bonjour ${name},</h2>
      <p>Merci de nous avoir contactés ! Votre message a bien été reçu et un ticket de suivi a été créé.</p>
      
      <div class="ticket-box">
        <p class="label">Numéro de ticket</p>
        <p class="number">${ticketNumber}</p>
        <p class="subject">« ${subject} »</p>
      </div>

      <p><strong>Conservez ce numéro</strong> : il vous permettra de suivre l'avancement de votre demande.</p>

      <div class="steps">
        <div class="step">
          <div class="step-num">1</div>
          <div class="step-text"><strong>Réception</strong> — Notre équipe a bien reçu votre message.</div>
        </div>
        <div class="step">
          <div class="step-num">2</div>
          <div class="step-text"><strong>Traitement</strong> — Un membre de l'équipe prendra en charge votre demande sous 24 h.</div>
        </div>
        <div class="step">
          <div class="step-num">3</div>
          <div class="step-text"><strong>Réponse</strong> — Vous recevrez une réponse par email à l'adresse que vous avez fournie.</div>
        </div>
      </div>

      <div class="info-box">
        <p>💡 <strong>Besoin urgent ?</strong> Contactez-nous directement par téléphone au 05 56 00 00 00 (Lun – Ven, 9 h – 18 h).</p>
      </div>
    </div>
    <div class="footer">
      <p>© ${new Date().getFullYear()} Vite & Gourmand — Tous droits réservés</p>
      <p>Cet email a été envoyé automatiquement, merci de ne pas y répondre directement.</p>
    </div>
  </div>
</body>
</html>`;
  }
}
