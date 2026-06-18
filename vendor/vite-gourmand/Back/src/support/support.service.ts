/**
 * Support Service
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import type { Prisma } from '../../generated/prisma/client.js';
import {
  CreateSupportTicketDto,
  UpdateSupportTicketDto,
  CreateTicketMessageDto,
  TicketStatus,
} from './dto/support.dto';

@Injectable()
export class SupportService {
  constructor(private readonly prisma: PrismaService) {}

  private generateTicketNumber(): string {
    const date = new Date();
    const prefix = `TK${date.getFullYear()}${String(date.getMonth() + 1).padStart(2, '0')}`;
    const random = Math.random().toString(36).substring(2, 8).toUpperCase();
    return `${prefix}-${random}`;
  }

  async findAll(options?: {
    status?: string;
    assignedTo?: number;
    createdBy?: number;
    limit?: number;
    offset?: number;
  }) {
    const where: Prisma.SupportTicketWhereInput = {};
    if (options?.status) where.status = options.status;
    if (options?.assignedTo) where.assigned_to = options.assignedTo;
    if (options?.createdBy) where.created_by = options.createdBy;

    return this.prisma.supportTicket.findMany({
      where,
      include: {
        User_SupportTicket_created_byToUser: {
          select: { id: true, first_name: true, last_name: true, email: true },
        },
        User_SupportTicket_assigned_toToUser: {
          select: { id: true, first_name: true, last_name: true },
        },
        TicketMessage: {
          take: 1,
          orderBy: { created_at: 'desc' },
        },
      },
      orderBy: [{ priority: 'desc' }, { created_at: 'desc' }],
      take: options?.limit || 50,
      skip: options?.offset || 0,
    });
  }

  async findById(id: number) {
    const ticket = await this.prisma.supportTicket.findUnique({
      where: { id },
      include: {
        User_SupportTicket_created_byToUser: {
          select: {
            id: true,
            first_name: true,
            last_name: true,
            email: true,
            phone_number: true,
          },
        },
        User_SupportTicket_assigned_toToUser: {
          select: { id: true, first_name: true, last_name: true },
        },
        TicketMessage: {
          include: {
            User: { select: { id: true, first_name: true, last_name: true } },
          },
          orderBy: { created_at: 'asc' },
        },
      },
    });
    if (!ticket) throw new NotFoundException('Support ticket not found');
    return ticket;
  }

  async findByTicketNumber(ticketNumber: string) {
    const ticket = await this.prisma.supportTicket.findUnique({
      where: { ticket_number: ticketNumber },
      include: {
        User_SupportTicket_created_byToUser: {
          select: { id: true, first_name: true, last_name: true, email: true },
        },
        TicketMessage: {
          where: { is_internal: false },
          include: {
            User: { select: { id: true, first_name: true, last_name: true } },
          },
          orderBy: { created_at: 'asc' },
        },
      },
    });
    if (!ticket) throw new NotFoundException('Support ticket not found');
    return ticket;
  }

  async create(userId: number, dto: CreateSupportTicketDto) {
    return this.prisma.supportTicket.create({
      data: {
        ticket_number: this.generateTicketNumber(),
        created_by: userId,
        category: dto.category,
        subject: dto.subject,
        description: dto.description,
        priority: dto.priority || 'normal',
        status: 'open',
      },
    });
  }

  async update(id: number, dto: UpdateSupportTicketDto) {
    await this.findById(id);

    const data: Prisma.SupportTicketUncheckedUpdateInput = {};
    if (dto.status !== undefined) data.status = dto.status;
    if (dto.priority !== undefined) data.priority = dto.priority;
    if (dto.assignedTo !== undefined) data.assigned_to = dto.assignedTo;

    // Update timestamps
    if (dto.status === TicketStatus.RESOLVED) data.resolved_at = new Date();
    if (dto.status === TicketStatus.CLOSED) data.closed_at = new Date();

    return this.prisma.supportTicket.update({
      where: { id },
      data,
      include: {
        User_SupportTicket_assigned_toToUser: {
          select: { id: true, first_name: true, last_name: true },
        },
      },
    });
  }

  async addMessage(
    ticketId: number,
    userId: number,
    dto: CreateTicketMessageDto,
  ) {
    await this.findById(ticketId);

    return this.prisma.ticketMessage.create({
      data: {
        ticket_id: ticketId,
        user_id: userId,
        body: dto.body,
        is_internal: dto.isInternal || false,
      },
      include: {
        User: { select: { id: true, first_name: true, last_name: true } },
      },
    });
  }

  async getMyTickets(
    userId: number,
    options?: { limit?: number; offset?: number },
  ) {
    return this.findAll({ createdBy: userId, ...options });
  }

  async getAssignedTickets(
    userId: number,
    options?: { limit?: number; offset?: number },
  ) {
    return this.findAll({ assignedTo: userId, ...options });
  }

  async getOpenTickets() {
    return this.findAll({ status: 'open' });
  }

  async assignTicket(ticketId: number, assigneeId: number) {
    return this.update(ticketId, {
      assignedTo: assigneeId,
      status: TicketStatus.IN_PROGRESS,
    });
  }

  async resolveTicket(ticketId: number) {
    return this.update(ticketId, { status: TicketStatus.RESOLVED });
  }

  async closeTicket(ticketId: number) {
    return this.update(ticketId, { status: TicketStatus.CLOSED });
  }

  async getStats() {
    const [open, inProgress, resolved, closed] = await Promise.all([
      this.prisma.supportTicket.count({ where: { status: 'open' } }),
      this.prisma.supportTicket.count({ where: { status: 'in_progress' } }),
      this.prisma.supportTicket.count({ where: { status: 'resolved' } }),
      this.prisma.supportTicket.count({ where: { status: 'closed' } }),
    ]);

    return {
      open,
      inProgress,
      resolved,
      closed,
      total: open + inProgress + resolved + closed,
    };
  }
}
