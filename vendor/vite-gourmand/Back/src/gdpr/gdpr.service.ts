/**
 * GDPR Service - Facade for GDPR operations
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import { ConsentService } from './consent.service';
import { DataDeletionService } from './data-deletion.service';
import {
  CreateUserConsentDto,
  UpdateUserConsentDto,
  CreateDataDeletionRequestDto,
  ProcessDataDeletionRequestDto,
} from './dto/gdpr.dto';

@Injectable()
export class GdprService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly consentService: ConsentService,
    private readonly dataDeletionService: DataDeletionService,
  ) {}

  // Consent operations - delegate to ConsentService
  getUserConsents(userId: number) {
    return this.consentService.getUserConsents(userId);
  }
  getUserConsent(userId: number, type: string) {
    return this.consentService.getUserConsent(userId, type);
  }
  setUserConsent(userId: number, dto: CreateUserConsentDto) {
    return this.consentService.setUserConsent(userId, dto);
  }
  updateConsent(userId: number, type: string, dto: UpdateUserConsentDto) {
    return this.consentService.updateConsent(userId, type, dto);
  }
  withdrawAllConsents(userId: number) {
    return this.consentService.withdrawAllConsents(userId);
  }

  // Data deletion operations - delegate to DataDeletionService
  createDeletionRequest(userId: number, dto: CreateDataDeletionRequestDto) {
    return this.dataDeletionService.createRequest(userId, dto);
  }
  getMyDeletionRequest(userId: number) {
    return this.dataDeletionService.getMyRequest(userId);
  }
  cancelDeletionRequest(userId: number) {
    return this.dataDeletionService.cancelRequest(userId);
  }
  getAllDeletionRequests(options: { status?: string }) {
    return this.dataDeletionService.getAllRequests(options.status);
  }
  getPendingDeletionRequests() {
    return this.dataDeletionService.getPendingRequests();
  }
  getDeletionRequestById(id: number) {
    return this.dataDeletionService.getRequestById(id);
  }
  processDeletionRequest(
    id: number,
    dto: ProcessDataDeletionRequestDto,
    adminId: number,
  ) {
    return this.dataDeletionService.processRequest(id, dto, adminId);
  }

  /** Export user data (GDPR data portability) */
  async exportUserData(userId: number) {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      include: {
        UserAddress: true,
        Order: true,
        Publish_Publish_user_idToUser: true,
        UserConsent: true,
        LoyaltyAccount: { include: { LoyaltyTransaction: true } },
      },
    });
    if (!user) throw new NotFoundException('User not found');
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    const { password, ...exportData } = user;
    return { exportedAt: new Date().toISOString(), data: exportData };
  }
}
