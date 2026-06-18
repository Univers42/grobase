import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { NotificationService } from './notification.service';
import { PrismaService } from '../../prisma';

describe('NotificationService', () => {
  let service: NotificationService;
  let prisma: jest.Mocked<PrismaService>;

  const mockNotification = {
    id: 1,
    user_id: 1,
    title: 'Test Notification',
    body: 'This is a test notification',
    type: 'info',
    is_read: false,
    link_url: '/orders/1',
    created_at: new Date(),
    read_at: null,
  };

  beforeEach(async () => {
    const mockPrisma = {
      notification: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        count: jest.fn(),
        create: jest.fn(),
        createMany: jest.fn(),
        update: jest.fn(),
        updateMany: jest.fn(),
        delete: jest.fn(),
        deleteMany: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        NotificationService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<NotificationService>(NotificationService);
    prisma = module.get(PrismaService);
  });

  describe('findAll', () => {
    it('should return user notifications', async () => {
      (prisma.notification.findMany as jest.Mock).mockResolvedValue([
        mockNotification,
      ]);

      const result = await service.findAll(1);

      expect(result).toHaveLength(1);
      expect(prisma.notification.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { user_id: 1 },
        }),
      );
    });

    it('should filter by unread only', async () => {
      (prisma.notification.findMany as jest.Mock).mockResolvedValue([
        mockNotification,
      ]);

      await service.findAll(1, { unreadOnly: true });

      expect(prisma.notification.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { user_id: 1, is_read: false },
        }),
      );
    });

    it('should respect limit and offset', async () => {
      (prisma.notification.findMany as jest.Mock).mockResolvedValue([
        mockNotification,
      ]);

      await service.findAll(1, { limit: 10, offset: 5 });

      expect(prisma.notification.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          take: 10,
          skip: 5,
        }),
      );
    });
  });

  describe('findById', () => {
    it('should return a notification by id', async () => {
      (prisma.notification.findUnique as jest.Mock).mockResolvedValue(
        mockNotification,
      );

      const result = await service.findById(1);

      expect(result).toEqual(mockNotification);
    });

    it('should throw NotFoundException if not found', async () => {
      (prisma.notification.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('getUnreadCount', () => {
    it('should return count of unread notifications', async () => {
      (prisma.notification.count as jest.Mock).mockResolvedValue(5);

      const result = await service.getUnreadCount(1);

      expect(result).toBe(5);
      expect(prisma.notification.count).toHaveBeenCalledWith({
        where: { user_id: 1, is_read: false },
      });
    });
  });

  describe('markAsRead', () => {
    it('should mark notification as read', async () => {
      (prisma.notification.findUnique as jest.Mock).mockResolvedValue(
        mockNotification,
      );
      (prisma.notification.update as jest.Mock).mockResolvedValue({
        ...mockNotification,
        is_read: true,
        read_at: new Date(),
      });

      const result = await service.markAsRead(1, 1);

      expect(result.is_read).toBe(true);
      expect(result.read_at).toBeDefined();
    });

    it('should throw NotFoundException if notification not found', async () => {
      (prisma.notification.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.markAsRead(999, 1)).rejects.toThrow(
        NotFoundException,
      );
    });

    it('should throw NotFoundException if notification belongs to another user', async () => {
      (prisma.notification.findUnique as jest.Mock).mockResolvedValue({
        ...mockNotification,
        user_id: 2,
      });

      await expect(service.markAsRead(1, 1)).rejects.toThrow(NotFoundException);
    });
  });

  describe('markAllAsRead', () => {
    it('should mark all user notifications as read', async () => {
      (prisma.notification.updateMany as jest.Mock).mockResolvedValue({
        count: 5,
      });

      const result = await service.markAllAsRead(1);

      expect(result.count).toBe(5);
      expect(prisma.notification.updateMany).toHaveBeenCalledWith({
        where: { user_id: 1, is_read: false },
        data: expect.objectContaining({ is_read: true }),
      });
    });
  });

  describe('create', () => {
    it('should create a notification', async () => {
      const createDto = {
        userId: 1,
        title: 'New Order',
        body: 'Your order has been placed',
        type: 'order',
      };
      (prisma.notification.create as jest.Mock).mockResolvedValue({
        id: 2,
        user_id: createDto.userId,
        title: createDto.title,
        body: createDto.body,
        type: createDto.type,
        is_read: false,
      });

      const result = await service.create(createDto);

      expect(result.title).toBe('New Order');
      expect(result.is_read).toBe(false);
    });
  });

  describe('createBulk', () => {
    it('should send notifications to multiple users', async () => {
      const bulkDto = {
        userIds: [1, 2, 3],
        title: 'Announcement',
        body: 'System maintenance tonight',
        type: 'system',
      };
      (prisma.notification.createMany as jest.Mock).mockResolvedValue({
        count: 3,
      });

      const result = await service.createBulk(bulkDto);

      expect(result.count).toBe(3);
    });
  });

  describe('delete', () => {
    it('should delete a notification', async () => {
      (prisma.notification.findUnique as jest.Mock).mockResolvedValue(
        mockNotification,
      );
      (prisma.notification.delete as jest.Mock).mockResolvedValue(
        mockNotification,
      );

      const result = await service.delete(1, 1);

      expect(result.message).toBe('Notification deleted successfully');
    });

    it('should throw NotFoundException if notification not found', async () => {
      (prisma.notification.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.delete(999, 1)).rejects.toThrow(NotFoundException);
    });

    it('should throw NotFoundException if notification belongs to another user', async () => {
      (prisma.notification.findUnique as jest.Mock).mockResolvedValue({
        ...mockNotification,
        user_id: 2,
      });

      await expect(service.delete(1, 1)).rejects.toThrow(NotFoundException);
    });
  });

  describe('deleteAll', () => {
    it('should delete all notifications for user', async () => {
      (prisma.notification.deleteMany as jest.Mock).mockResolvedValue({
        count: 10,
      });

      const result = await service.deleteAll(1);

      expect(result.message).toBe('All notifications deleted successfully');
    });
  });

  describe('notifyOrderStatus', () => {
    it('should create order status notification', async () => {
      (prisma.notification.create as jest.Mock).mockResolvedValue({
        id: 3,
        user_id: 1,
        type: 'order_update',
        title: 'Commande confirmée',
        body: 'Votre commande #1 a été confirmée',
        is_read: false,
      });

      const result = await service.notifyOrderStatus(1, 1, 'confirmed');

      expect(result.type).toBe('order_update');
      expect(result.title).toBe('Commande confirmée');
    });
  });
});
