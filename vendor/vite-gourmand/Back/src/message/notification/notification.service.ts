/**
 * Notification Service
 */
import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../../prisma';
import type { Prisma } from '../../../generated/prisma/client.js';
import {
  CreateNotificationDto,
  BulkNotificationDto,
} from './dto/notification.dto';

@Injectable()
export class NotificationService {
  constructor(private readonly prisma: PrismaService) {}

  async findAll(
    userId: number,
    options?: { unreadOnly?: boolean; limit?: number; offset?: number },
  ) {
    const where: Prisma.NotificationWhereInput = { user_id: userId };
    if (options?.unreadOnly) where.is_read = false;

    return this.prisma.notification.findMany({
      where,
      orderBy: { created_at: 'desc' },
      take: options?.limit || 50,
      skip: options?.offset || 0,
    });
  }

  async findById(id: number) {
    const notification = await this.prisma.notification.findUnique({
      where: { id },
    });
    if (!notification) throw new NotFoundException('Notification not found');
    return notification;
  }

  async create(dto: CreateNotificationDto) {
    return this.prisma.notification.create({
      data: {
        user_id: dto.userId,
        type: dto.type,
        title: dto.title,
        body: dto.body,
        link_url: dto.linkUrl,
      },
    });
  }

  async createBulk(dto: BulkNotificationDto) {
    const notifications = dto.userIds.map((userId) => ({
      user_id: userId,
      type: dto.type,
      title: dto.title,
      body: dto.body,
      link_url: dto.linkUrl,
    }));

    return this.prisma.notification.createMany({ data: notifications });
  }

  async markAsRead(id: number, userId: number) {
    const notification = await this.findById(id);
    if (notification.user_id !== userId) {
      throw new NotFoundException('Notification not found');
    }

    return this.prisma.notification.update({
      where: { id },
      data: { is_read: true, read_at: new Date() },
    });
  }

  async markAllAsRead(userId: number) {
    return this.prisma.notification.updateMany({
      where: { user_id: userId, is_read: false },
      data: { is_read: true, read_at: new Date() },
    });
  }

  async delete(id: number, userId: number) {
    const notification = await this.findById(id);
    if (notification.user_id !== userId) {
      throw new NotFoundException('Notification not found');
    }

    await this.prisma.notification.delete({ where: { id } });
    return { message: 'Notification deleted successfully' };
  }

  async deleteAll(userId: number) {
    await this.prisma.notification.deleteMany({ where: { user_id: userId } });
    return { message: 'All notifications deleted successfully' };
  }

  async getUnreadCount(userId: number) {
    return this.prisma.notification.count({
      where: { user_id: userId, is_read: false },
    });
  }

  // Helper to send common notification types
  async notifyOrderStatus(userId: number, orderId: number, status: string) {
    const messages: Record<string, { title: string; body: string }> = {
      confirmed: {
        title: 'Commande confirmée',
        body: `Votre commande #${orderId} a été confirmée`,
      },
      preparing: {
        title: 'En préparation',
        body: `Votre commande #${orderId} est en cours de préparation`,
      },
      ready: {
        title: 'Commande prête',
        body: `Votre commande #${orderId} est prête`,
      },
      delivering: {
        title: 'En livraison',
        body: `Votre commande #${orderId} est en cours de livraison`,
      },
      delivered: {
        title: 'Commande livrée',
        body: `Votre commande #${orderId} a été livrée`,
      },
      cancelled: {
        title: 'Commande annulée',
        body: `Votre commande #${orderId} a été annulée`,
      },
    };

    const msg = messages[status] || {
      title: 'Mise à jour',
      body: `Statut de votre commande: ${status}`,
    };

    return this.create({
      userId,
      type: 'order_update',
      title: msg.title,
      body: msg.body,
      linkUrl: `/orders/${orderId}`,
    });
  }
}
