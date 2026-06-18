/**
 * Employee Time Off Service - Employee-facing operations
 */
import {
  Injectable,
  NotFoundException,
  BadRequestException,
  ForbiddenException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import {
  CreateTimeOffRequestDto,
  UpdateTimeOffRequestDto,
} from './dto/timeoff.dto';

@Injectable()
export class EmployeeTimeOffService {
  constructor(private readonly prisma: PrismaService) {}

  /** Create time off request */
  async create(dto: CreateTimeOffRequestDto, userId: number) {
    const startDate = new Date(dto.start_date);
    const endDate = new Date(dto.end_date);
    if (endDate < startDate)
      throw new BadRequestException('End date must be after start date');

    const overlapping = await this.prisma.timeOffRequest.findFirst({
      where: {
        user_id: userId,
        status: { in: ['pending', 'approved'] },
        OR: [{ start_date: { lte: endDate }, end_date: { gte: startDate } }],
      },
    });
    if (overlapping)
      throw new BadRequestException('You have an overlapping time-off request');

    return this.prisma.timeOffRequest.create({
      data: {
        user_id: userId,
        type: dto.request_type,
        start_date: startDate,
        end_date: endDate,
        reason: dto.reason,
        status: 'pending',
      },
    });
  }

  /** Get my requests */
  async getMyRequests(userId: number) {
    return this.prisma.timeOffRequest.findMany({
      where: { user_id: userId },
      orderBy: { requested_at: 'desc' },
    });
  }

  /** Update my pending request */
  async update(id: number, dto: UpdateTimeOffRequestDto, userId: number) {
    const request = await this.getRequestOrFail(id);
    if (request.user_id !== userId)
      throw new ForbiddenException('You can only update your own requests');
    if (request.status !== 'pending')
      throw new BadRequestException('Can only update pending requests');

    const updateData: {
      type?: string;
      reason?: string;
      start_date?: Date;
      end_date?: Date;
    } = {};
    if (dto.request_type) updateData.type = dto.request_type;
    if (dto.reason !== undefined) updateData.reason = dto.reason;
    if (dto.start_date) updateData.start_date = new Date(dto.start_date);
    if (dto.end_date) updateData.end_date = new Date(dto.end_date);
    if (
      updateData.start_date &&
      updateData.end_date &&
      updateData.end_date < updateData.start_date
    ) {
      throw new BadRequestException('End date must be after start date');
    }
    return this.prisma.timeOffRequest.update({
      where: { id },
      data: updateData,
    });
  }

  /** Cancel my request */
  async cancel(id: number, userId: number) {
    const request = await this.getRequestOrFail(id);
    if (request.user_id !== userId)
      throw new ForbiddenException('You can only cancel your own requests');
    if (request.status !== 'pending')
      throw new BadRequestException('Can only cancel pending requests');
    return this.prisma.timeOffRequest.update({
      where: { id },
      data: { status: 'cancelled' },
    });
  }

  private async getRequestOrFail(id: number) {
    const request = await this.prisma.timeOffRequest.findUnique({
      where: { id },
    });
    if (!request) throw new NotFoundException('Time off request not found');
    return request;
  }
}
