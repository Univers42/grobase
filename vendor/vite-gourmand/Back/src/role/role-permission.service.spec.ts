/**
 * Role-Permission Service Unit Tests
 */
import { Test, TestingModule } from '@nestjs/testing';
import { RolePermissionService } from './role-permission.service';
import { PrismaService } from '../prisma';
import { NotFoundException } from '@nestjs/common';

describe('RolePermissionService', () => {
  let service: RolePermissionService;

  const mockRole = {
    id: 1,
    name: 'admin',
    RolePermission: [{ Permission: { name: 'read_users' } }],
  };
  const mockUser = {
    id: 1,
    Role: { RolePermission: [{ Permission: { id: 1, name: 'read_users' } }] },
  };
  const mockPrisma = {
    role: { findUnique: jest.fn() },
    rolePermission: {
      findMany: jest.fn(),
      createMany: jest.fn(),
      deleteMany: jest.fn(),
    },
    user: { findUnique: jest.fn() },
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        RolePermissionService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();
    service = module.get<RolePermissionService>(RolePermissionService);
    jest.clearAllMocks();
  });

  describe('assignPermissions', () => {
    it('should assign new permissions to a role', async () => {
      mockPrisma.role.findUnique.mockResolvedValue(mockRole);
      mockPrisma.rolePermission.findMany.mockResolvedValue([
        { permission_id: 1 },
      ]);
      mockPrisma.rolePermission.createMany.mockResolvedValue({ count: 1 });
      await service.assignPermissions(1, [1, 2]);
      expect(mockPrisma.rolePermission.createMany).toHaveBeenCalled();
    });

    it('should throw NotFoundException when role not found', async () => {
      mockPrisma.role.findUnique.mockResolvedValue(null);
      await expect(service.assignPermissions(999, [1])).rejects.toThrow(
        NotFoundException,
      );
    });
  });

  describe('removePermissions', () => {
    it('should remove permissions from a role', async () => {
      mockPrisma.role.findUnique.mockResolvedValue(mockRole);
      mockPrisma.rolePermission.deleteMany.mockResolvedValue({ count: 1 });
      await service.removePermissions(1, [1]);
      expect(mockPrisma.rolePermission.deleteMany).toHaveBeenCalled();
    });
  });

  describe('userHasPermission', () => {
    it('should return true when user has permission', async () => {
      mockPrisma.user.findUnique.mockResolvedValue(mockUser);
      const result = await service.userHasPermission(1, 'read_users');
      expect(result).toBe(true);
    });

    it('should return false when user lacks permission', async () => {
      mockPrisma.user.findUnique.mockResolvedValue(mockUser);
      const result = await service.userHasPermission(1, 'delete_users');
      expect(result).toBe(false);
    });

    it('should return false when user has no role', async () => {
      mockPrisma.user.findUnique.mockResolvedValue({ id: 1, Role: null });
      const result = await service.userHasPermission(1, 'read_users');
      expect(result).toBe(false);
    });
  });

  describe('getUserPermissions', () => {
    it('should return user permissions', async () => {
      mockPrisma.user.findUnique.mockResolvedValue(mockUser);
      const result = await service.getUserPermissions(1);
      expect(result).toEqual([{ id: 1, name: 'read_users' }]);
    });

    it('should return empty array when user has no role', async () => {
      mockPrisma.user.findUnique.mockResolvedValue({ id: 1, Role: null });
      const result = await service.getUserPermissions(1);
      expect(result).toEqual([]);
    });
  });
});
