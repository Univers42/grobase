import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { UserService } from './user.service';
import { PrismaService } from '../prisma';

describe('UserService', () => {
  let service: UserService;
  let prisma: jest.Mocked<PrismaService>;

  const mockDbUser = {
    id: 1,
    first_name: 'John',
    last_name: 'Doe',
    email: 'john@test.com',
    phone_number: '0612345678',
    city: 'Paris',
    is_deleted: false,
    Role: { name: 'client' },
  };

  const mockSanitizedUser = {
    id: 1,
    email: 'john@test.com',
    firstName: 'John',
    lastName: 'Doe',
    phoneNumber: '0612345678',
    city: 'Paris',
    postalCode: undefined,
    country: undefined,
    preferredLanguage: undefined,
    isActive: undefined,
    isEmailVerified: undefined,
    gdprConsent: undefined,
    marketingConsent: undefined,
    createdAt: undefined,
    updatedAt: undefined,
    lastLoginAt: undefined,
    role: 'client',
    loyaltyAccount: null,
  };

  beforeEach(async () => {
    const mockPrisma = {
      user: {
        findUnique: jest.fn(),
        findMany: jest.fn(),
        count: jest.fn(),
        update: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        UserService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<UserService>(UserService);
    prisma = module.get(PrismaService);
  });

  describe('findById', () => {
    it('should return sanitized user by id', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockDbUser);

      const result = await service.findById(1);

      expect(result).toEqual(mockSanitizedUser);
    });

    it('should throw NotFoundException when user not found', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('findAll', () => {
    it('should return paginated sanitized users', async () => {
      (prisma.user.findMany as jest.Mock).mockResolvedValue([mockDbUser]);
      (prisma.user.count as jest.Mock).mockResolvedValue(1);

      const result = await service.findAll({ page: 1, limit: 10 });

      expect(result.items).toHaveLength(1);
      expect(result.items[0]).toEqual(mockSanitizedUser);
      expect(result.meta).toBeDefined();
    });
  });

  describe('update', () => {
    it('should update and return sanitized user', async () => {
      const updateDto = { firstName: 'Jane', phoneNumber: '0698765432' };
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockDbUser);
      (prisma.user.update as jest.Mock).mockResolvedValue({
        ...mockDbUser,
        first_name: 'Jane',
        phone_number: '0698765432',
      });

      const result = await service.update(1, updateDto);

      expect(result.firstName).toBe('Jane');
      expect(result.phoneNumber).toBe('0698765432');
    });

    it('should throw if user not found during update', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.update(999, { firstName: 'Test' })).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('softDelete', () => {
    it('should soft delete user account', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockDbUser);
      (prisma.user.update as jest.Mock).mockResolvedValue({
        ...mockDbUser,
        is_deleted: true,
      });

      const result = await service.softDelete(1);

      expect(result.message).toBe('Account deleted successfully');
    });

    it('should throw if user not found for soft delete', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.softDelete(999)).rejects.toThrow(NotFoundException);
    });
  });
});
