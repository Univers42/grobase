/**
 * Data Deletion Service - GDPR data deletion requests
 */
import {
  Injectable,
  NotFoundException,
  BadRequestException,
  ConflictException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import {
  CreateDataDeletionRequestDto,
  ProcessDataDeletionRequestDto,
  DataDeletionStatus,
} from './dto/gdpr.dto';

@Injectable()
export class DataDeletionService {
  constructor(private readonly prisma: PrismaService) {}

  private readonly userSel = {
    id: true,
    email: true,
    first_name: true,
    last_name: true,
    created_at: true,
  };

  /** Create data deletion request */
  async createRequest(userId: number, dto: CreateDataDeletionRequestDto) {
    const existing = await this.prisma.dataDeletionRequest.findFirst({
      where: { user_id: userId, status: { in: ['pending', 'in_progress'] } },
    });
    if (existing)
      throw new ConflictException('Pending data deletion request exists');
    return this.prisma.dataDeletionRequest.create({
      data: { user_id: userId, reason: dto.reason, status: 'pending' },
    });
  }

  /** Get my deletion request */
  async getMyRequest(userId: number) {
    return this.prisma.dataDeletionRequest.findFirst({
      where: { user_id: userId },
      orderBy: { requested_at: 'desc' },
    });
  }

  /** Cancel my deletion request */
  async cancelRequest(userId: number) {
    const req = await this.prisma.dataDeletionRequest.findFirst({
      where: { user_id: userId, status: 'pending' },
    });
    if (!req) throw new NotFoundException('No pending deletion request');
    return this.prisma.dataDeletionRequest.delete({ where: { id: req.id } });
  }

  /** Get all deletion requests (admin) */
  async getAllRequests(status?: string) {
    return this.prisma.dataDeletionRequest.findMany({
      where: status ? { status } : undefined,
      include: {
        User_DataDeletionRequest_user_idToUser: { select: this.userSel },
        User_DataDeletionRequest_processed_byToUser: {
          select: { id: true, first_name: true, last_name: true },
        },
      },
      orderBy: { requested_at: 'desc' },
    });
  }

  /** Get pending deletion requests (admin) */
  getPendingRequests() {
    return this.getAllRequests('pending');
  }

  /** Get deletion request by ID (admin) */
  async getRequestById(id: number) {
    const req = await this.prisma.dataDeletionRequest.findUnique({
      where: { id },
      include: {
        User_DataDeletionRequest_user_idToUser: { select: this.userSel },
        User_DataDeletionRequest_processed_byToUser: {
          select: { id: true, first_name: true, last_name: true },
        },
      },
    });
    if (!req) throw new NotFoundException('Deletion request not found');
    return req;
  }

  /** Process deletion request (admin) */
  async processRequest(
    id: number,
    dto: ProcessDataDeletionRequestDto,
    adminId: number,
  ) {
    const req = await this.prisma.dataDeletionRequest.findUnique({
      where: { id },
    });
    if (!req) throw new NotFoundException('Deletion request not found');
    if (req.status === 'completed')
      throw new BadRequestException('Request already completed');
    if (dto.status === DataDeletionStatus.COMPLETED && req.user_id)
      await this.performDeletion(req.user_id);
    return this.prisma.dataDeletionRequest.update({
      where: { id },
      data: {
        status: dto.status,
        processed_by: adminId,
        processed_at: new Date(),
      },
    });
  }

  /** Perform actual data deletion/anonymization */
  private async performDeletion(userId: number) {
    await this.prisma.$transaction([
      this.prisma.user.update({
        where: { id: userId },
        data: {
          email: `deleted-${userId}@anonymized.local`,
          first_name: 'Deleted',
          last_name: 'User',
          phone_number: null,
          is_active: false,
          is_deleted: true,
          marketing_consent: false,
          newsletter_consent: false,
          gdpr_consent: false,
          gdpr_consent_date: null,
          newsletter_consent_date: null,
        },
      }),
      this.prisma.userConsent.deleteMany({ where: { user_id: userId } }),
      this.prisma.userSession.deleteMany({ where: { user_id: userId } }),
      this.prisma.userAddress.deleteMany({ where: { user_id: userId } }),
    ]);
  }
}
