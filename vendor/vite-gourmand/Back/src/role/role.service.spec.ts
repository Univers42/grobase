/**
 * Role Service Unit Tests
 */
import { Test, TestingModule } from '@nestjs/testing';
import { RoleService } from './role.service';
import { PrismaService } from '../prisma';
import { NotFoundException, ConflictException } from '@nestjs/common';

describe('RoleService', () => {
  let service: RoleService;

  const mockRole = {
    id: 1,
    name: 'admin',
    description: 'Administrator',
    RolePermission: [],
    User: [],
  };
  const mockPrisma = {
    role: {
      findMany: jest.fn(),
      findUnique: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      delete: jest.fn(),
    },
    rolePermission: { createMany: jest.fn(), deleteMany: jest.fn() },
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        RoleService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();
    service = module.get<RoleService>(RoleService);
    jest.clearAllMocks();
  });

  describe('findAll', () => {
    it('should return all roles', async () => {
      mockPrisma.role.findMany.mockResolvedValue([mockRole]);
      const result = await service.findAll();
      expect(result).toEqual([mockRole]);
    });
  });

  describe('findById', () => {
    it('should return role by id', async () => {
      mockPrisma.role.findUnique.mockResolvedValue(mockRole);
      const result = await service.findById(1);
      expect(result).toEqual(mockRole);
    });

    it('should throw NotFoundException when role not found', async () => {
      mockPrisma.role.findUnique.mockResolvedValue(null);
      await expect(service.findById(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('create', () => {
    it('should create a role', async () => {
      mockPrisma.role.findUnique
        .mockResolvedValueOnce(null)
        .mockResolvedValueOnce(mockRole);
      mockPrisma.role.create.mockResolvedValue(mockRole);
      const result = await service.create({ name: 'admin' });
      expect(result).toEqual(mockRole);
    });

    it('should throw ConflictException for duplicate name', async () => {
      mockPrisma.role.findUnique.mockResolvedValue(mockRole);
      await expect(service.create({ name: 'admin' })).rejects.toThrow(
        ConflictException,
      );
    });
  });

  describe('update', () => {
    it('should update a role', async () => {
      // First call for findById, second for checkDuplicate (should return null for new name)
      mockPrisma.role.findUnique
        .mockResolvedValueOnce(mockRole)
        .mockResolvedValueOnce(null)
        .mockResolvedValueOnce({ ...mockRole, name: 'updated' });
      mockPrisma.role.update.mockResolvedValue({
        ...mockRole,
        name: 'updated',
      });
      await service.update(1, { name: 'updated' });
      expect(mockPrisma.role.update).toHaveBeenCalled();
    });
  });

  describe('delete', () => {
    it('should delete a role', async () => {
      mockPrisma.role.findUnique.mockResolvedValue({
        ...mockRole,
        _count: { User: 0 },
      });
      mockPrisma.role.delete.mockResolvedValue(mockRole);
      await service.delete(1);
      expect(mockPrisma.role.delete).toHaveBeenCalledWith({ where: { id: 1 } });
    });

    it('should throw ConflictException when role has users', async () => {
      mockPrisma.role.findUnique.mockResolvedValue({
        ...mockRole,
        _count: { User: 5 },
      });
      await expect(service.delete(1)).rejects.toThrow(ConflictException);
    });
  });
});
