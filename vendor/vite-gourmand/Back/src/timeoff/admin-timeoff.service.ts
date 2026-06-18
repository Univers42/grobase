/**
 * Admin Time Off Service - Admin operations
 */
import {
  Injectable,
  NotFoundException,
  BadRequestException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import { DecideTimeOffRequestDto } from './dto/timeoff.dto';

@Injectable()
export class AdminTimeOffService {
  constructor(private readonly prisma: PrismaService) {}

  private readonly userSelect = {
    id: true,
    first_name: true,
    last_name: true,
    email: true,
  };
  private readonly deciderSelect = {
    id: true,
    first_name: true,
    last_name: true,
  };

  /** Get all requests */
  async findAll(options: { status?: string; userId?: number }) {
    const where: { status?: string; user_id?: number } = {};
    if (options.status) where.status = options.status;
    if (options.userId) where.user_id = options.userId;
    return this.prisma.timeOffRequest.findMany({
      where,
      include: {
        User_TimeOffRequest_user_idToUser: { select: this.userSelect },
        User_TimeOffRequest_decided_byToUser: { select: this.deciderSelect },
      },
      orderBy: { requested_at: 'desc' },
    });
  }

  /** Get pending requests */
  getPending() {
    return this.findAll({ status: 'pending' });
  }

  /** Get request by ID */
  async findById(id: number) {
    const request = await this.prisma.timeOffRequest.findUnique({
      where: { id },
      include: {
        User_TimeOffRequest_user_idToUser: { select: this.userSelect },
        User_TimeOffRequest_decided_byToUser: { select: this.deciderSelect },
      },
    });
    if (!request) throw new NotFoundException('Time off request not found');
    return request;
  }

  /** Decide on request (approve/reject) */
  async decide(id: number, dto: DecideTimeOffRequestDto, deciderId: number) {
    const request = await this.prisma.timeOffRequest.findUnique({
      where: { id },
    });
    if (!request) throw new NotFoundException('Time off request not found');
    if (request.status !== 'pending')
      throw new BadRequestException('Can only decide on pending requests');
    return this.prisma.timeOffRequest.update({
      where: { id },
      data: {
        status: dto.status,
        decided_by: deciderId,
        decided_at: new Date(),
      },
    });
  }

  /** Delete request */
  async delete(id: number) {
    const request = await this.prisma.timeOffRequest.findUnique({
      where: { id },
    });
    if (!request) throw new NotFoundException('Time off request not found');
    return this.prisma.timeOffRequest.delete({ where: { id } });
  }

  /** Get employee schedule */
  async getSchedule(startDate: Date, endDate: Date) {
    return this.prisma.timeOffRequest.findMany({
      where: {
        status: 'approved',
        OR: [{ start_date: { lte: endDate }, end_date: { gte: startDate } }],
      },
      include: {
        User_TimeOffRequest_user_idToUser: {
          select: { first_name: true, last_name: true },
        },
      },
      orderBy: { start_date: 'asc' },
    });
  }
}
