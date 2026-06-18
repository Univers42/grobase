import { Test, TestingModule } from '@nestjs/testing';
import { BadRequestException } from '@nestjs/common';
import { LoyaltyService } from './loyalty.service';
import { PrismaService } from '../prisma';
import { LoyaltyTransactionType } from './dto/loyalty.dto';

describe('LoyaltyService', () => {
  let service: LoyaltyService;
  let prisma: jest.Mocked<PrismaService>;

  const mockLoyaltyAccount = {
    id: 1,
    user_id: 1,
    balance: 500,
    total_earned: 1000,
    total_spent: 500,
    last_activity_at: new Date(),
  };

  const mockTransaction = {
    id: 1,
    loyalty_account_id: 1,
    points: 100,
    type: 'earn',
    description: 'Order #123',
    order_id: null,
    created_at: new Date(),
  };

  beforeEach(async () => {
    const mockPrisma = {
      loyaltyAccount: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
      },
      loyaltyTransaction: {
        findMany: jest.fn(),
        create: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        LoyaltyService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<LoyaltyService>(LoyaltyService);
    prisma = module.get(PrismaService);
  });

  describe('getAccount', () => {
    it('should return existing loyalty account', async () => {
      (prisma.loyaltyAccount.findUnique as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );

      const result = await service.getAccount(1);

      expect(result.balance).toBe(500);
      expect(result.total_earned).toBe(1000);
    });

    it('should create new account if none exists', async () => {
      (prisma.loyaltyAccount.findUnique as jest.Mock).mockResolvedValue(null);
      (prisma.loyaltyAccount.create as jest.Mock).mockResolvedValue({
        ...mockLoyaltyAccount,
        balance: 0,
        total_earned: 0,
        total_spent: 0,
      });

      await service.getAccount(1);

      expect(prisma.loyaltyAccount.create).toHaveBeenCalled();
    });
  });

  describe('getAccountWithTransactions', () => {
    it('should return account with transactions', async () => {
      (prisma.loyaltyAccount.findUnique as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );
      (prisma.loyaltyAccount.create as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );
      (prisma.loyaltyTransaction.findMany as jest.Mock).mockResolvedValue([
        mockTransaction,
      ]);

      const result = await service.getAccountWithTransactions(1);

      expect(result.account).toBeDefined();
      expect(result.transactions).toHaveLength(1);
    });
  });

  describe('getAllAccounts', () => {
    it('should return all loyalty accounts', async () => {
      (prisma.loyaltyAccount.findMany as jest.Mock).mockResolvedValue([
        mockLoyaltyAccount,
      ]);

      const result = await service.getAllAccounts();

      expect(result).toHaveLength(1);
    });
  });

  describe('earnPoints', () => {
    it('should add points to account', async () => {
      (prisma.loyaltyAccount.findUnique as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );
      (prisma.loyaltyAccount.create as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );
      (prisma.loyaltyTransaction.create as jest.Mock).mockResolvedValue(
        mockTransaction,
      );
      (prisma.loyaltyAccount.update as jest.Mock).mockResolvedValue({
        ...mockLoyaltyAccount,
        balance: 600,
        total_earned: 1100,
      });

      await service.earnPoints(1, {
        points: 100,
        type: LoyaltyTransactionType.EARN,
        description: 'Test order',
      });

      expect(prisma.loyaltyTransaction.create).toHaveBeenCalled();
    });

    it('should throw BadRequestException for non-positive points', async () => {
      await expect(
        service.earnPoints(1, {
          points: 0,
          type: LoyaltyTransactionType.EARN,
          description: 'Test',
        }),
      ).rejects.toThrow(BadRequestException);
    });
  });

  describe('earnPointsFromOrder', () => {
    it('should calculate and add points from order', async () => {
      (prisma.loyaltyAccount.findUnique as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );
      (prisma.loyaltyAccount.create as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );
      (prisma.loyaltyTransaction.create as jest.Mock).mockResolvedValue(
        mockTransaction,
      );
      (prisma.loyaltyAccount.update as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );

      await service.earnPointsFromOrder(1, 123, 50); // 50€ = 500 points

      expect(prisma.loyaltyTransaction.create).toHaveBeenCalled();
    });
  });

  describe('redeemPoints', () => {
    it('should redeem points for discount', async () => {
      (prisma.loyaltyAccount.findUnique as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );
      (prisma.loyaltyAccount.create as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );
      (prisma.loyaltyTransaction.create as jest.Mock).mockResolvedValue({
        ...mockTransaction,
        points: -200,
        type: 'redeem',
      });
      (prisma.loyaltyAccount.update as jest.Mock).mockResolvedValue({
        ...mockLoyaltyAccount,
        balance: 300,
        total_spent: 700,
      });

      const result = await service.redeemPoints(1, { points: 200 });

      expect(result.discountValue).toBe(2); // 200 points = 2€
      expect(prisma.loyaltyTransaction.create).toHaveBeenCalled();
    });

    it('should throw BadRequestException for insufficient balance', async () => {
      (prisma.loyaltyAccount.findUnique as jest.Mock).mockResolvedValue({
        ...mockLoyaltyAccount,
        balance: 100,
      });
      (prisma.loyaltyAccount.create as jest.Mock).mockResolvedValue({
        ...mockLoyaltyAccount,
        balance: 100,
      });

      await expect(service.redeemPoints(1, { points: 500 })).rejects.toThrow(
        BadRequestException,
      );
    });
  });

  describe('getPointsValue', () => {
    it('should calculate correct monetary value', async () => {
      const result = await service.getPointsValue(500);

      expect(result.points).toBe(500);
      expect(result.euroValue).toBe(5); // 500 points = 5€
    });
  });

  describe('addBonusPoints', () => {
    it('should add bonus points to user account', async () => {
      (prisma.loyaltyAccount.findUnique as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );
      (prisma.loyaltyAccount.create as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );
      (prisma.loyaltyTransaction.create as jest.Mock).mockResolvedValue({
        ...mockTransaction,
        type: 'bonus',
        description: 'Admin bonus',
      });
      (prisma.loyaltyAccount.update as jest.Mock).mockResolvedValue({
        ...mockLoyaltyAccount,
        balance: 700,
      });

      await service.addBonusPoints(1, 200, 'Admin bonus');

      expect(prisma.loyaltyTransaction.create).toHaveBeenCalled();
    });
  });

  describe('getTransactionHistory', () => {
    it('should return transaction history for user', async () => {
      (prisma.loyaltyAccount.findUnique as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );
      (prisma.loyaltyAccount.create as jest.Mock).mockResolvedValue(
        mockLoyaltyAccount,
      );
      (prisma.loyaltyTransaction.findMany as jest.Mock).mockResolvedValue([
        mockTransaction,
      ]);

      const result = await service.getTransactionHistory(1);

      expect(result).toHaveLength(1);
    });
  });
});
