/**
 * Data Deletion Service Unit Tests
 */
import { Test, TestingModule } from '@nestjs/testing';
import { DataDeletionService } from './data-deletion.service';
import { PrismaService } from '../prisma';
import {
  NotFoundException,
  ConflictException,
  BadRequestException,
} from '@nestjs/common';
import { DataDeletionStatus } from './dto/gdpr.dto';

describe('DataDeletionService', () => {
  let service: DataDeletionService;

  const mockRequest = {
    id: 1,
    user_id: 1,
    reason: 'Privacy',
    status: 'pending',
    requested_at: new Date(),
  };
  const mockPrisma = {
    dataDeletionRequest: {
      findFirst: jest.fn(),
      findUnique: jest.fn(),
      findMany: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      delete: jest.fn(),
    },
    user: { update: jest.fn() },
    userConsent: { deleteMany: jest.fn() },
    userSession: { deleteMany: jest.fn() },
    userAddress: { deleteMany: jest.fn() },
    $transaction: jest.fn((fns) => Promise.all(fns)),
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        DataDeletionService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();
    service = module.get<DataDeletionService>(DataDeletionService);
    jest.clearAllMocks();
  });

  describe('createRequest', () => {
    it('should create deletion request', async () => {
      mockPrisma.dataDeletionRequest.findFirst.mockResolvedValue(null);
      mockPrisma.dataDeletionRequest.create.mockResolvedValue(mockRequest);
      const result = await service.createRequest(1, { reason: 'Privacy' });
      expect(result).toEqual(mockRequest);
    });

    it('should throw ConflictException if request exists', async () => {
      mockPrisma.dataDeletionRequest.findFirst.mockResolvedValue(mockRequest);
      await expect(
        service.createRequest(1, { reason: 'Privacy' }),
      ).rejects.toThrow(ConflictException);
    });
  });

  describe('cancelRequest', () => {
    it('should cancel pending request', async () => {
      mockPrisma.dataDeletionRequest.findFirst.mockResolvedValue(mockRequest);
      mockPrisma.dataDeletionRequest.delete.mockResolvedValue(mockRequest);
      await service.cancelRequest(1);
      expect(mockPrisma.dataDeletionRequest.delete).toHaveBeenCalled();
    });

    it('should throw NotFoundException if no pending request', async () => {
      mockPrisma.dataDeletionRequest.findFirst.mockResolvedValue(null);
      await expect(service.cancelRequest(1)).rejects.toThrow(NotFoundException);
    });
  });

  describe('processRequest', () => {
    it('should throw BadRequestException if already completed', async () => {
      mockPrisma.dataDeletionRequest.findUnique.mockResolvedValue({
        ...mockRequest,
        status: 'completed',
      });
      await expect(
        service.processRequest(1, { status: DataDeletionStatus.COMPLETED }, 2),
      ).rejects.toThrow(BadRequestException);
    });
  });
});
