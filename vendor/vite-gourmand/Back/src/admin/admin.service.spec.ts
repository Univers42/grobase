import { Test, TestingModule } from '@nestjs/testing';
import { NotFoundException } from '@nestjs/common';
import { AdminService } from './admin.service';
import { PrismaService } from '../prisma';

describe('AdminService', () => {
  let service: AdminService;
  let prisma: jest.Mocked<PrismaService>;

  const mockUser = {
    id: 1,
    firstname: 'John',
    lastname: 'Doe',
    email: 'john@test.com',
    is_active: true,
    role_id: 2,
    Role: { id: 2, name: 'client' },
  };

  const mockRole = { id: 1, name: 'admin' };

  beforeEach(async () => {
    const mockPrisma = {
      user: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
      },
      role: {
        findMany: jest.fn(),
        findUnique: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        AdminService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();

    service = module.get<AdminService>(AdminService);
    prisma = module.get(PrismaService);
  });

  describe('getAllUsers', () => {
    it('should return all users', async () => {
      const users = [mockUser];
      (prisma.user.findMany as jest.Mock).mockResolvedValue(users);

      const result = await service.getAllUsers();

      expect(result).toEqual(users);
      expect(prisma.user.findMany).toHaveBeenCalled();
    });
  });

  describe('createEmployee', () => {
    it('should create a new employee', async () => {
      const dto = {
        email: 'employee@test.com',
        password: 'password123',
        firstName: 'Jane',
        lastName: 'Doe',
        roleId: 3,
      };
      (prisma.user.create as jest.Mock).mockResolvedValue({
        id: 2,
        ...dto,
      });

      const result = await service.createEmployee(dto);

      expect(result.email).toBe(dto.email);
      expect(prisma.user.create).toHaveBeenCalled();
    });
  });

  describe('updateUserRole', () => {
    it('should update user role', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockUser);
      (prisma.role.findUnique as jest.Mock).mockResolvedValue(mockRole);
      (prisma.user.update as jest.Mock).mockResolvedValue({
        ...mockUser,
        role_id: 1,
      });

      await service.updateUserRole(1, 1);

      expect(prisma.user.update).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: 1 },
          data: { role_id: 1 },
        }),
      );
    });

    it('should throw if user not found', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.updateUserRole(999, 1)).rejects.toThrow(
        NotFoundException,
      );
    });

    it('should throw if role not found', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockUser);
      (prisma.role.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.updateUserRole(1, 999)).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('toggleUserActive', () => {
    it('should toggle user active status', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockUser);
      (prisma.user.update as jest.Mock).mockResolvedValue({
        ...mockUser,
        is_active: false,
      });

      await service.toggleUserActive(1);

      expect(prisma.user.update).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: 1 },
          data: { is_active: false },
        }),
      );
    });

    it('should throw if user not found', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.toggleUserActive(999)).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('getRoles', () => {
    it('should return all roles', async () => {
      const roles = [mockRole, { id: 2, name: 'client' }];
      (prisma.role.findMany as jest.Mock).mockResolvedValue(roles);

      const result = await service.getRoles();

      expect(result).toEqual(roles);
    });
  });
});
