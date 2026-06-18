import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException, BadRequestException } from '@nestjs/common';
import { DeliveryService } from './delivery.service';
import { PrismaService } from '../prisma';

describe('DeliveryService', () => {
  let service: DeliveryService;
  let prisma: jest.Mocked<PrismaService>;

  const mockDelivery = {
    id: 1,
    order_id: 1,
    delivery_person_id: 2,
    vehicle_type: 'bike',
    status: 'assigned',
    assigned_at: new Date(),
    picked_up_at: null,
    delivered_at: null,
    delivery_notes: 'Ring bell twice',
    proof_photo_url: null,
    client_rating: null,
    Order: {
      id: 1,
      order_number: 'ORD-001',
      delivery_address: '123 Main St',
    },
    User: {
      id: 2,
      first_name: 'Delivery',
      last_name: 'Person',
      phone_number: '123456789',
    },
  };

  beforeEach(async () => {
    const mockPrisma = {
      deliveryAssignment: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        findFirst: jest.fn(),
        count: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
        delete: jest.fn(),
      },
      order: {
        findUnique: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        DeliveryService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<DeliveryService>(DeliveryService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return all deliveries', async () => {
      (prisma.deliveryAssignment.findMany as jest.Mock).mockResolvedValue([
        mockDelivery,
      ]);

      const result = await service.findAll();

      expect(result).toHaveLength(1);
    });

    it('should filter by status', async () => {
      (prisma.deliveryAssignment.findMany as jest.Mock).mockResolvedValue([
        mockDelivery,
      ]);

      await service.findAll({ status: 'assigned' });

      expect(prisma.deliveryAssignment.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ status: 'assigned' }),
        }),
      );
    });

    it('should filter by delivery person', async () => {
      (prisma.deliveryAssignment.findMany as jest.Mock).mockResolvedValue([
        mockDelivery,
      ]);

      await service.findAll({ deliveryPersonId: 2 });

      expect(prisma.deliveryAssignment.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: expect.objectContaining({ delivery_person_id: 2 }),
        }),
      );
    });
  });

  describe('findById', () => {
    it('should return a delivery by id', async () => {
      (prisma.deliveryAssignment.findUnique as jest.Mock).mockResolvedValue(
        mockDelivery,
      );

      const result = await service.findById(1);

      expect(result).toEqual(mockDelivery);
    });

    it('should throw NotFoundException if not found', async () => {
      (prisma.deliveryAssignment.findUnique as jest.Mock).mockResolvedValue(
        null,
      );

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('findByOrderId', () => {
    it('should return delivery for an order', async () => {
      (prisma.deliveryAssignment.findFirst as jest.Mock).mockResolvedValue(
        mockDelivery,
      );

      const result = await service.findByOrderId(1);

      expect(result?.order_id).toBe(1);
    });

    it('should return null if not found', async () => {
      (prisma.deliveryAssignment.findFirst as jest.Mock).mockResolvedValue(
        null,
      );

      const result = await service.findByOrderId(999);

      expect(result).toBeNull();
    });
  });

  describe('create', () => {
    it('should create a delivery assignment', async () => {
      const createDto = {
        orderId: 2,
        deliveryPersonId: 3,
        vehicleType: 'car',
      };
      (prisma.order.findUnique as jest.Mock).mockResolvedValue({ id: 2 });
      (prisma.deliveryAssignment.findFirst as jest.Mock).mockResolvedValue(
        null,
      );
      (prisma.deliveryAssignment.create as jest.Mock).mockResolvedValue({
        id: 2,
        order_id: 2,
        delivery_person_id: 3,
        vehicle_type: 'car',
        status: 'assigned',
      });

      const result = await service.create(createDto);

      expect(result.order_id).toBe(2);
      expect(result.status).toBe('assigned');
    });

    it('should throw NotFoundException if order not found', async () => {
      (prisma.order.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(
        service.create({ orderId: 999, deliveryPersonId: 1 }),
      ).rejects.toThrow(NotFoundException);
    });

    it('should throw BadRequestException if assignment already exists', async () => {
      (prisma.order.findUnique as jest.Mock).mockResolvedValue({ id: 1 });
      (prisma.deliveryAssignment.findFirst as jest.Mock).mockResolvedValue(
        mockDelivery,
      );

      await expect(
        service.create({ orderId: 1, deliveryPersonId: 1 }),
      ).rejects.toThrow(BadRequestException);
    });
  });

  describe('update', () => {
    it('should update a delivery assignment', async () => {
      (prisma.deliveryAssignment.findUnique as jest.Mock).mockResolvedValue(
        mockDelivery,
      );
      (prisma.deliveryAssignment.update as jest.Mock).mockResolvedValue({
        ...mockDelivery,
        delivery_notes: 'Updated notes',
      });

      const result = await service.update(1, {
        deliveryNotes: 'Updated notes',
      });

      expect(result.delivery_notes).toBe('Updated notes');
    });
  });

  describe('markPickedUp', () => {
    it('should mark delivery as picked up', async () => {
      (prisma.deliveryAssignment.findUnique as jest.Mock).mockResolvedValue(
        mockDelivery,
      );
      (prisma.deliveryAssignment.update as jest.Mock).mockResolvedValue({
        ...mockDelivery,
        status: 'picked_up',
        picked_up_at: new Date(),
      });

      const result = await service.markPickedUp(1);

      expect(result.status).toBe('picked_up');
      expect(result.picked_up_at).toBeDefined();
    });
  });

  describe('markDelivered', () => {
    it('should mark delivery as delivered', async () => {
      (prisma.deliveryAssignment.findUnique as jest.Mock).mockResolvedValue(
        mockDelivery,
      );
      (prisma.deliveryAssignment.update as jest.Mock).mockResolvedValue({
        ...mockDelivery,
        status: 'delivered',
        delivered_at: new Date(),
        proof_photo_url: 'https://example.com/photo.jpg',
      });

      const result = await service.markDelivered(
        1,
        'https://example.com/photo.jpg',
      );

      expect(result.status).toBe('delivered');
      expect(result.delivered_at).toBeDefined();
    });
  });

  describe('rateDelivery', () => {
    it('should rate a delivery', async () => {
      (prisma.deliveryAssignment.findUnique as jest.Mock).mockResolvedValue(
        mockDelivery,
      );
      (prisma.deliveryAssignment.update as jest.Mock).mockResolvedValue({
        ...mockDelivery,
        client_rating: 5,
      });

      const result = await service.rateDelivery(1, { rating: 5 });

      expect(result.client_rating).toBe(5);
    });
  });

  describe('getMyDeliveries', () => {
    it('should return deliveries for delivery person', async () => {
      (prisma.deliveryAssignment.findMany as jest.Mock).mockResolvedValue([
        mockDelivery,
      ]);

      const result = await service.getMyDeliveries(2);

      expect(result).toHaveLength(1);
    });
  });

  describe('getPendingDeliveries', () => {
    it('should return pending deliveries', async () => {
      (prisma.deliveryAssignment.findMany as jest.Mock).mockResolvedValue([
        mockDelivery,
      ]);

      const result = await service.getPendingDeliveries();

      expect(result).toHaveLength(1);
    });
  });

  describe('delete', () => {
    it('should delete a delivery assignment', async () => {
      (prisma.deliveryAssignment.findUnique as jest.Mock).mockResolvedValue(
        mockDelivery,
      );
      (prisma.deliveryAssignment.delete as jest.Mock).mockResolvedValue(
        mockDelivery,
      );

      const result = await service.delete(1);

      expect(result.message).toBe('Delivery assignment deleted successfully');
    });
  });
});
