/**
 * Permission Service Unit Tests
 */
import { Test, TestingModule } from '@nestjs/testing';
import { PermissionService } from './permission.service';
import { PrismaService } from '../prisma';
import { NotFoundException, ConflictException } from '@nestjs/common';

describe('PermissionService', () => {
  let service: PermissionService;

  const mockPermission = {
    id: 1,
    name: 'read_users',
    resource: 'users',
    action: 'read',
  };
  const mockPrisma = {
    permission: {
      findMany: jest.fn(),
      findUnique: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      delete: jest.fn(),
    },
    rolePermission: { deleteMany: jest.fn() },
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        PermissionService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();
    service = module.get<PermissionService>(PermissionService);
    jest.clearAllMocks();
  });

  describe('findAll', () => {
    it('should return all permissions', async () => {
      mockPrisma.permission.findMany.mockResolvedValue([mockPermission]);
      const result = await service.findAll();
      expect(result).toEqual([mockPermission]);
    });
  });

  describe('findById', () => {
    it('should return permission by id', async () => {
      mockPrisma.permission.findUnique.mockResolvedValue(mockPermission);
      const result = await service.findById(1);
      expect(result).toEqual(mockPermission);
    });

    it('should throw NotFoundException when not found', async () => {
      mockPrisma.permission.findUnique.mockResolvedValue(null);
      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('findByName', () => {
    it('should return permission by name', async () => {
      mockPrisma.permission.findUnique.mockResolvedValue(mockPermission);
      const result = await service.findByName('read_users');
      expect(result).toEqual(mockPermission);
    });
  });

  describe('create', () => {
    it('should create a permission', async () => {
      mockPrisma.permission.findUnique.mockResolvedValue(null);
      mockPrisma.permission.create.mockResolvedValue(mockPermission);
      const result = await service.create({
        name: 'read_users',
        resource: 'users',
        action: 'read',
      });
      expect(result).toEqual(mockPermission);
    });

    it('should throw ConflictException for duplicate name', async () => {
      mockPrisma.permission.findUnique.mockResolvedValue(mockPermission);
      await expect(service.create({ name: 'read_users' })).rejects.toThrow(
        ConflictException,
      );
    });
  });

  describe('update', () => {
    it('should update a permission', async () => {
      // First call for findById, second for findByName (should return null for different name)
      mockPrisma.permission.findUnique
        .mockResolvedValueOnce(mockPermission)
        .mockResolvedValueOnce(null);
      mockPrisma.permission.update.mockResolvedValue({
        ...mockPermission,
        name: 'updated',
      });
      await service.update(1, { name: 'updated' });
      expect(mockPrisma.permission.update).toHaveBeenCalled();
    });
  });

  describe('delete', () => {
    it('should delete a permission', async () => {
      mockPrisma.permission.findUnique.mockResolvedValue(mockPermission);
      mockPrisma.permission.delete.mockResolvedValue(mockPermission);
      await service.delete(1);
      expect(mockPrisma.rolePermission.deleteMany).toHaveBeenCalledWith({
        where: { permission_id: 1 },
      });
      expect(mockPrisma.permission.delete).toHaveBeenCalledWith({
        where: { id: 1 },
      });
    });
  });
});
