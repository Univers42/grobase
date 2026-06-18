/**
 * Message Service
 */
import {
  Injectable,
  NotFoundException,
  ForbiddenException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import type { Prisma } from '../../generated/prisma/client.js';
import { CreateMessageDto, ReplyMessageDto } from './dto/message.dto';

@Injectable()
export class MessageService {
  constructor(private readonly prisma: PrismaService) {}

  async getInbox(
    userId: number,
    options?: { unreadOnly?: boolean; limit?: number; offset?: number },
  ) {
    const where: Prisma.MessageWhereInput = { recipient_id: userId };
    if (options?.unreadOnly) where.is_read = false;

    return this.prisma.message.findMany({
      where,
      include: {
        User_Message_sender_idToUser: {
          select: { id: true, first_name: true, last_name: true, email: true },
        },
      },
      orderBy: { sent_at: 'desc' },
      take: options?.limit || 50,
      skip: options?.offset || 0,
    });
  }

  async getSent(userId: number, options?: { limit?: number; offset?: number }) {
    return this.prisma.message.findMany({
      where: { sender_id: userId },
      include: {
        User_Message_recipient_idToUser: {
          select: { id: true, first_name: true, last_name: true, email: true },
        },
      },
      orderBy: { sent_at: 'desc' },
      take: options?.limit || 50,
      skip: options?.offset || 0,
    });
  }

  async findById(id: number, userId: number) {
    const message = await this.prisma.message.findUnique({
      where: { id },
      include: {
        User_Message_sender_idToUser: {
          select: { id: true, first_name: true, last_name: true, email: true },
        },
        User_Message_recipient_idToUser: {
          select: { id: true, first_name: true, last_name: true, email: true },
        },
        other_Message: {
          include: {
            User_Message_sender_idToUser: {
              select: { id: true, first_name: true, last_name: true },
            },
          },
        },
      },
    });
    if (!message) throw new NotFoundException('Message not found');
    if (message.sender_id !== userId && message.recipient_id !== userId) {
      throw new ForbiddenException('Access denied');
    }
    return message;
  }

  async getThread(messageId: number, userId: number) {
    // Validate access - findById throws if user doesn't have access
    await this.findById(messageId, userId);

    // Get all messages in thread
    const thread = await this.prisma.message.findMany({
      where: {
        OR: [{ id: messageId }, { parent_id: messageId }],
      },
      include: {
        User_Message_sender_idToUser: {
          select: { id: true, first_name: true, last_name: true },
        },
      },
      orderBy: { sent_at: 'asc' },
    });

    return thread;
  }

  async send(senderId: number, dto: CreateMessageDto) {
    return this.prisma.message.create({
      data: {
        sender_id: senderId,
        recipient_id: dto.recipientId,
        subject: dto.subject,
        body: dto.body,
        priority: dto.priority || 'normal',
        parent_id: dto.parentId,
      },
      include: {
        User_Message_recipient_idToUser: {
          select: { id: true, first_name: true, last_name: true, email: true },
        },
      },
    });
  }

  async reply(userId: number, messageId: number, dto: ReplyMessageDto) {
    const original = await this.findById(messageId, userId);

    // Determine recipient (the other person in the conversation)
    const recipientId =
      original.sender_id === userId
        ? original.recipient_id
        : original.sender_id;

    return this.prisma.message.create({
      data: {
        sender_id: userId,
        recipient_id: recipientId,
        subject: original.subject ? `Re: ${original.subject}` : null,
        body: dto.body,
        priority: original.priority,
        parent_id: messageId,
      },
    });
  }

  async markAsRead(id: number, userId: number) {
    const message = await this.findById(id, userId);
    if (message.recipient_id !== userId) {
      throw new ForbiddenException('Cannot mark this message as read');
    }

    return this.prisma.message.update({
      where: { id },
      data: { is_read: true, read_at: new Date() },
    });
  }

  async delete(id: number, userId: number) {
    await this.findById(id, userId);
    await this.prisma.message.delete({ where: { id } });
    return { message: 'Message deleted successfully' };
  }

  async getUnreadCount(userId: number) {
    return this.prisma.message.count({
      where: { recipient_id: userId, is_read: false },
    });
  }
}
