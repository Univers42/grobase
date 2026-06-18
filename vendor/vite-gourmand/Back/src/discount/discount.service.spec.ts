import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException, BadRequestException } from '@nestjs/common';
import { DiscountService } from './discount.service';
import { PrismaService } from '../prisma';
import { DiscountType } from './dto/discount.dto';

describe('DiscountService', () => {
  let service: DiscountService;
  let prisma: jest.Mocked<PrismaService>;

  const mockDiscount = {
    id: 1,
    code: 'SAVE20',
    description: '20% off',
    type: 'percentage',
    value: 20,
    min_order_amount: 50,
    max_uses: 100,
    current_uses: 10,
    valid_from: new Date('2025-01-01'),
    valid_until: new Date('2026-12-31'),
    is_active: true,
    created_at: new Date(),
    created_by: null,
  };

  beforeEach(async () => {
    const mockPrisma = {
      discount: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        findFirst: jest.fn(),
        count: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        DiscountService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<DiscountService>(DiscountService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return all discounts', async () => {
      (prisma.discount.findMany as jest.Mock).mockResolvedValue([mockDiscount]);

      const result = await service.findAll();

      expect(result).toHaveLength(1);
      expect(result[0].code).toBe('SAVE20');
    });

    it('should filter active discounts only', async () => {
      (prisma.discount.findMany as jest.Mock).mockResolvedValue([mockDiscount]);

      await service.findAll({ activeOnly: true });

      expect(prisma.discount.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ is_active: true }),
        }),
      );
    });
  });

  describe('findById', () => {
    it('should return a discount by id', async () => {
      (prisma.discount.findUnique as jest.Mock).mockResolvedValue(mockDiscount);

      const result = await service.findById(1);

      expect(result).toEqual(mockDiscount);
    });

    it('should throw NotFoundException if not found', async () => {
      (prisma.discount.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('findByCode', () => {
    it('should return a discount by code', async () => {
      (prisma.discount.findUnique as jest.Mock).mockResolvedValue(mockDiscount);

      const result = await service.findByCode('SAVE20');

      expect(result.code).toBe('SAVE20');
    });

    it('should throw NotFoundException if code not found', async () => {
      (prisma.discount.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findByCode('INVALID')).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('create', () => {
    it('should create a discount', async () => {
      const createDto = {
        code: 'NEW10',
        type: DiscountType.PERCENTAGE,
        value: 10,
      };
      (prisma.discount.create as jest.Mock).mockResolvedValue({
        id: 2,
        ...createDto,
        is_active: true,
      });

      const result = await service.create(createDto);

      expect(result.code).toBe('NEW10');
    });
  });

  describe('update', () => {
    it('should update a discount', async () => {
      (prisma.discount.findUnique as jest.Mock).mockResolvedValue(mockDiscount);
      (prisma.discount.update as jest.Mock).mockResolvedValue({
        ...mockDiscount,
        value: 25,
      });

      const result = await service.update(1, { value: 25 });

      expect(result.value).toBe(25);
    });
  });

  describe('validate', () => {
    it('should validate a valid discount code', async () => {
      (prisma.discount.findUnique as jest.Mock).mockResolvedValue(mockDiscount);

      const result = await service.validate({
        code: 'SAVE20',
        orderAmount: 100,
      });

      expect(result.valid).toBe(true);
      expect(result.discount).toBeDefined();
    });

    it('should reject if minimum order amount not met', async () => {
      (prisma.discount.findUnique as jest.Mock).mockResolvedValue(mockDiscount);

      await expect(
        service.validate({ code: 'SAVE20', orderAmount: 30 }),
      ).rejects.toThrow(BadRequestException);
    });

    it('should reject if max uses exceeded', async () => {
      const exhaustedDiscount = { ...mockDiscount, current_uses: 100 };
      (prisma.discount.findUnique as jest.Mock).mockResolvedValue(
        exhaustedDiscount,
      );

      await expect(
        service.validate({ code: 'SAVE20', orderAmount: 100 }),
      ).rejects.toThrow(BadRequestException);
    });

    it('should reject inactive discount', async () => {
      const inactiveDiscount = { ...mockDiscount, is_active: false };
      (prisma.discount.findUnique as jest.Mock).mockResolvedValue(
        inactiveDiscount,
      );

      await expect(
        service.validate({ code: 'SAVE20', orderAmount: 100 }),
      ).rejects.toThrow(BadRequestException);
    });
  });

  describe('delete', () => {
    it('should delete a discount', async () => {
      (prisma.discount.findUnique as jest.Mock).mockResolvedValue(mockDiscount);
      (prisma.discount.delete as jest.Mock).mockResolvedValue(mockDiscount);

      const result = await service.delete(1);

      expect(result.message).toBe('Discount deleted successfully');
    });

    it('should throw NotFoundException if not found', async () => {
      (prisma.discount.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.delete(999)).rejects.toThrow(NotFoundException);
    });
  });
});
