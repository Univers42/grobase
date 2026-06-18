/**
 * User Consent Service - Manage GDPR consents
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { CreateUserConsentDto, UpdateUserConsentDto } from './dto/gdpr.dto';

@Injectable()
export class ConsentService {
  constructor(private readonly prisma: PrismaService) {}

  /** Get all consents for user */
  async getUserConsents(userId: number) {
    return this.prisma.userConsent.findMany({
      where: { user_id: userId },
      orderBy: { consent_type: 'asc' },
    });
  }

  /** Get specific consent for user */
  async getUserConsent(userId: number, consentType: string) {
    return this.prisma.userConsent.findFirst({
      where: { user_id: userId, consent_type: consentType },
    });
  }

  /** Set user consent (create or update) */
  async setUserConsent(userId: number, dto: CreateUserConsentDto) {
    const existing = await this.getUserConsent(userId, dto.consent_type);

    if (existing) {
      return this.prisma.userConsent.update({
        where: { id: existing.id },
        data: {
          is_granted: dto.consented,
          granted_at: dto.consented ? new Date() : null,
          revoked_at: dto.consented ? null : new Date(),
        },
      });
    }

    return this.prisma.userConsent.create({
      data: {
        user_id: userId,
        consent_type: dto.consent_type,
        is_granted: dto.consented,
        granted_at: dto.consented ? new Date() : null,
      },
    });
  }

  /** Update consent */
  async updateConsent(
    userId: number,
    consentType: string,
    dto: UpdateUserConsentDto,
  ) {
    const consent = await this.getUserConsent(userId, consentType);
    if (!consent) throw new NotFoundException('Consent not found');

    return this.prisma.userConsent.update({
      where: { id: consent.id },
      data: {
        is_granted: dto.consented,
        granted_at: dto.consented ? new Date() : consent.granted_at,
        revoked_at: dto.consented ? null : new Date(),
      },
    });
  }

  /** Withdraw all consents (except essential) */
  async withdrawAllConsents(userId: number) {
    return this.prisma.userConsent.updateMany({
      where: { user_id: userId, consent_type: { not: 'essential' } },
      data: { is_granted: false, revoked_at: new Date() },
    });
  }
}
