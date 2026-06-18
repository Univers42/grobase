/**
 * Order Status Service
 * Handle order status transitions and history
 */
import { Injectable, BadRequestException } from '@nestjs/common';
import { PrismaService } from '../prisma';

const STATUS_FLOW: Record<string, string[]> = {
  pending: ['confirmed', 'cancelled'],
  confirmed: ['preparing', 'cancelled'],
  preparing: ['ready', 'cancelled'],
  ready: ['delivering'],
  delivering: ['delivered'],
  delivered: [],
  cancelled: [],
};

@Injectable()
export class OrderStatusService {
  constructor(private readonly prisma: PrismaService) {}

  async updateStatus(orderId: number, newStatus: string, notes?: string) {
    const order = await this.prisma.order.findUnique({
      where: { id: orderId },
    });

    if (!order) throw new BadRequestException('Order not found');
    this.validateTransition(order.status, newStatus);

    const [updatedOrder] = await this.prisma.$transaction([
      this.prisma.order.update({
        where: { id: orderId },
        data: {
          status: newStatus,
          ...this.getStatusTimestamp(newStatus),
        },
      }),
      this.prisma.orderStatusHistory.create({
        data: {
          order_id: orderId,
          old_status: order.status,
          new_status: newStatus,
          notes,
        },
      }),
    ]);

    return updatedOrder;
  }

  async getHistory(orderId: number) {
    return this.prisma.orderStatusHistory.findMany({
      where: { order_id: orderId },
      orderBy: { changed_at: 'asc' },
    });
  }

  private validateTransition(current: string | null, next: string): void {
    const allowed = STATUS_FLOW[current ?? 'pending'] ?? [];
    if (!allowed.includes(next)) {
      throw new BadRequestException(
        `Cannot transition from ${current} to ${next}`,
      );
    }
  }

  private getStatusTimestamp(status: string): Record<string, Date> {
    const now = new Date();
    const timestamps: Record<string, Record<string, Date>> = {
      confirmed: { confirmed_at: now },
      delivered: { delivered_at: now },
      cancelled: { cancelled_at: now },
    };
    return timestamps[status] ?? {};
  }
}
