/**
 * Stats Service
 */
import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma';

@Injectable()
export class StatsService {
  constructor(private readonly prisma: PrismaService) {}

  async getDashboardStats() {
    const [users, orders, revenue, pendingOrders] = await Promise.all([
      this.getUserStats(),
      this.getOrderStats(),
      this.getRevenueStats(),
      this.getPendingOrderCount(),
    ]);

    return { users, orders, revenue, pendingOrders };
  }

  private async getUserStats() {
    const total = await this.prisma.user.count({
      where: { is_deleted: false },
    });
    const newThisMonth = await this.prisma.user.count({
      where: {
        is_deleted: false,
        created_at: { gte: this.getMonthStart() },
      },
    });
    return { total, newThisMonth };
  }

  private async getOrderStats() {
    const total = await this.prisma.order.count();
    const thisMonth = await this.prisma.order.count({
      where: { created_at: { gte: this.getMonthStart() } },
    });
    return { total, thisMonth };
  }

  private async getRevenueStats() {
    const result = await this.prisma.order.aggregate({
      where: { status: 'delivered' },
      _sum: { total_price: true },
    });
    return { total: result._sum.total_price ?? 0 };
  }

  private async getPendingOrderCount() {
    return this.prisma.order.count({
      where: { status: { in: ['pending', 'confirmed', 'preparing'] } },
    });
  }

  private getMonthStart(): Date {
    const now = new Date();
    return new Date(now.getFullYear(), now.getMonth(), 1);
  }
}
