/**
 * Loyalty Service
 */
import { Injectable, BadRequestException } from '@nestjs/common';
import { PrismaService } from '../prisma';
import {
  CreateLoyaltyTransactionDto,
  RedeemPointsDto,
  LoyaltyTransactionType,
} from './dto/loyalty.dto';

@Injectable()
export class LoyaltyService {
  constructor(private readonly prisma: PrismaService) {}

  // Points conversion rate: 1€ spent = 10 points
  private readonly POINTS_PER_EURO = 10;
  // Redemption rate: 100 points = 1€ discount
  private readonly POINTS_TO_EURO = 100;

  async getAccount(userId: number) {
    let account = await this.prisma.loyaltyAccount.findUnique({
      where: { user_id: userId },
    });

    // Auto-create account if doesn't exist
    if (!account) {
      account = await this.prisma.loyaltyAccount.create({
        data: { user_id: userId },
      });
    }

    return account;
  }

  async getAccountWithTransactions(userId: number) {
    const account = await this.getAccount(userId);
    const transactions = await this.prisma.loyaltyTransaction.findMany({
      where: { loyalty_account_id: account.id },
      orderBy: { created_at: 'desc' },
      take: 50,
    });

    return { account, transactions };
  }

  async getAllAccounts(options?: { limit?: number; offset?: number }) {
    return this.prisma.loyaltyAccount.findMany({
      include: {
        User: {
          select: { id: true, email: true, first_name: true, last_name: true },
        },
      },
      orderBy: { balance: 'desc' },
      take: options?.limit || 50,
      skip: options?.offset || 0,
    });
  }

  async earnPoints(userId: number, dto: CreateLoyaltyTransactionDto) {
    if (dto.points <= 0) {
      throw new BadRequestException('Points must be positive');
    }

    const account = await this.getAccount(userId);

    // Create transaction
    const transaction = await this.prisma.loyaltyTransaction.create({
      data: {
        loyalty_account_id: account.id,
        points: dto.points,
        type: dto.type,
        order_id: dto.orderId,
        description: dto.description,
      },
    });

    // Update account balance
    await this.prisma.loyaltyAccount.update({
      where: { id: account.id },
      data: {
        balance: { increment: dto.points },
        total_earned: { increment: dto.points },
        last_activity_at: new Date(),
      },
    });

    return transaction;
  }

  async earnPointsFromOrder(
    userId: number,
    orderId: number,
    orderAmount: number,
  ) {
    const points = Math.floor(orderAmount * this.POINTS_PER_EURO);
    return this.earnPoints(userId, {
      points,
      type: LoyaltyTransactionType.EARN,
      orderId,
      description: `Points earned from order #${orderId}`,
    });
  }

  async redeemPoints(userId: number, dto: RedeemPointsDto) {
    const account = await this.getAccount(userId);

    if (!account.balance || account.balance < dto.points) {
      throw new BadRequestException('Insufficient points balance');
    }

    // Create redemption transaction
    const orderLabel = dto.orderId ? ` for order #${dto.orderId}` : '';
    const transaction = await this.prisma.loyaltyTransaction.create({
      data: {
        loyalty_account_id: account.id,
        points: -dto.points,
        type: 'redeem',
        order_id: dto.orderId,
        description: `Points redeemed${orderLabel}`,
      },
    });

    // Update account balance
    await this.prisma.loyaltyAccount.update({
      where: { id: account.id },
      data: {
        balance: { decrement: dto.points },
        total_spent: { increment: dto.points },
        last_activity_at: new Date(),
      },
    });

    // Calculate discount value
    const discountValue = dto.points / this.POINTS_TO_EURO;

    return { transaction, discountValue };
  }

  async addBonusPoints(userId: number, points: number, description: string) {
    return this.earnPoints(userId, {
      points,
      type: LoyaltyTransactionType.BONUS,
      description,
    });
  }

  async getTransactionHistory(
    userId: number,
    options?: { limit?: number; offset?: number },
  ) {
    const account = await this.getAccount(userId);
    return this.prisma.loyaltyTransaction.findMany({
      where: { loyalty_account_id: account.id },
      orderBy: { created_at: 'desc' },
      take: options?.limit || 50,
      skip: options?.offset || 0,
    });
  }

  getPointsValue(points: number) {
    return {
      points,
      euroValue: points / this.POINTS_TO_EURO,
      conversionRate: `${this.POINTS_TO_EURO} points = 1€`,
    };
  }
}
