import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException, ForbiddenException } from '@nestjs/common';
import { OrderService } from './order.service';
import { PrismaService } from '../prisma';

describe('OrderService', () => {
  let service: OrderService;
  let prisma: jest.Mocked<PrismaService>;

  const mockOrder = {
    id: 1,
    user_id: 1,
    menu_id: 1,
    status: 'pending',
    qty: 2,
    delivery_date: new Date(),
    total_price: 50,
    Menu: { title: 'Menu Test' },
    User: { firstname: 'John' },
  };

  const mockUser = { sub: 1, role: 'client', email: 'client@test.com' };
  const mockAdmin = { sub: 2, role: 'admin', email: 'admin@test.com' };

  beforeEach(async () => {
    const mockPrisma = {
      order: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        count: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
      },
      menu: {
        findUnique: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        OrderService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<OrderService>(OrderService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return paginated orders', async () => {
      (prisma.order.findMany as jest.Mock).mockResolvedValue([mockOrder]);
      (prisma.order.count as jest.Mock).mockResolvedValue(1);

      const result = await service.findAll({ page: 1, limit: 10 });

      expect(result.items).toHaveLength(1);
      expect(result.meta).toBeDefined();
    });

    it('should filter by status', async () => {
      (prisma.order.findMany as jest.Mock).mockResolvedValue([mockOrder]);
      (prisma.order.count as jest.Mock).mockResolvedValue(1);

      await service.findAll({ page: 1, limit: 10, status: 'pending' });

      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ status: 'pending' }),
        }),
      );
    });
  });

  describe('findByUser', () => {
    it('should return orders for a specific user', async () => {
      (prisma.order.findMany as jest.Mock).mockResolvedValue([mockOrder]);
      (prisma.order.count as jest.Mock).mockResolvedValue(1);

      const result = await service.findByUser(1, { page: 1, limit: 10 });

      expect(result.items).toHaveLength(1);
      expect(prisma.order.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ user_id: 1 }),
        }),
      );
    });
  });

  describe('findById', () => {
    it('should return order for owner', async () => {
      (prisma.order.findUnique as jest.Mock).mockResolvedValue(mockOrder);

      const result = await service.findById(1, mockUser);

      expect(result).toEqual(mockOrder);
    });

    it('should return order for admin', async () => {
      (prisma.order.findUnique as jest.Mock).mockResolvedValue(mockOrder);

      const result = await service.findById(1, mockAdmin);

      expect(result).toEqual(mockOrder);
    });

    it('should throw if order not found', async () => {
      (prisma.order.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999, mockUser)).rejects.toThrow(
        NotFoundException,
      );
    });

    it('should throw forbidden for non-owner non-admin', async () => {
      (prisma.order.findUnique as jest.Mock).mockResolvedValue(mockOrder);
      const otherUser = { sub: 99, role: 'client', email: 'other@test.com' };

      await expect(service.findById(1, otherUser)).rejects.toThrow(
        ForbiddenException,
      );
    });
  });

  describe('create', () => {
    it('should create a new order', async () => {
      const dto = {
        deliveryDate: '2024-06-15',
        deliveryHour: '12:00',
        deliveryAddress: '123 Main Street',
        personNumber: 4,
        menuPrice: 100,
        totalPrice: 115,
      };
      (prisma.menu.findUnique as jest.Mock).mockResolvedValue({
        id: 1,
        price_per_person: 25,
      });
      (prisma.order.create as jest.Mock).mockResolvedValue({
        ...mockOrder,
        id: 2,
      });

      await service.create(1, dto);

      expect(prisma.order.create).toHaveBeenCalled();
    });
  });

  describe('update', () => {
    it('should update order as owner', async () => {
      (prisma.order.findUnique as jest.Mock).mockResolvedValue(mockOrder);
      (prisma.order.update as jest.Mock).mockResolvedValue({
        ...mockOrder,
        qty: 3,
      });

      await service.update(1, { specialInstructions: 'No nuts' }, mockUser);

      expect(prisma.order.update).toHaveBeenCalled();
    });

    it('should throw forbidden for non-owner', async () => {
      (prisma.order.findUnique as jest.Mock).mockResolvedValue(mockOrder);
      const otherUser = { sub: 99, role: 'client', email: 'other@test.com' };

      await expect(
        service.update(1, { specialInstructions: 'No nuts' }, otherUser),
      ).rejects.toThrow(ForbiddenException);
    });
  });

  describe('cancel', () => {
    it('should cancel order', async () => {
      (prisma.order.findUnique as jest.Mock).mockResolvedValue(mockOrder);
      (prisma.order.update as jest.Mock).mockResolvedValue({
        ...mockOrder,
        status: 'cancelled',
      });

      const result = await service.cancel(1, mockUser, 'Changed my mind');

      expect(result.status).toBe('cancelled');
    });
  });
});
