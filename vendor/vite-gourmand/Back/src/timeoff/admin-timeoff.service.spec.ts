/**
 * Admin Time Off Service Unit Tests
 */
import { Test, TestingModule } from '@nestjs/testing';
import { AdminTimeOffService } from './admin-timeoff.service';
import { PrismaService } from '../prisma';
import { BadRequestException } from '@nestjs/common';
import { TimeOffRequestStatus } from './dto/timeoff.dto';

describe('AdminTimeOffService', () => {
  let service: AdminTimeOffService;

  const mockRequest = { id: 1, user_id: 1, status: 'pending' };
  const mockPrisma = {
    timeOffRequest: {
      findUnique: jest.fn(),
      findMany: jest.fn(),
      update: jest.fn(),
      delete: jest.fn(),
    },
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        AdminTimeOffService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();
    service = module.get<AdminTimeOffService>(AdminTimeOffService);
    jest.clearAllMocks();
  });

  describe('findAll', () => {
    it('should return all requests', async () => {
      mockPrisma.timeOffRequest.findMany.mockResolvedValue([mockRequest]);
      const result = await service.findAll({});
      expect(result).toEqual([mockRequest]);
    });
  });

  describe('decide', () => {
    it('should approve request', async () => {
      mockPrisma.timeOffRequest.findUnique.mockResolvedValue(mockRequest);
      mockPrisma.timeOffRequest.update.mockResolvedValue({
        ...mockRequest,
        status: 'approved',
      });
      await service.decide(1, { status: TimeOffRequestStatus.APPROVED }, 2);
      expect(mockPrisma.timeOffRequest.update).toHaveBeenCalled();
    });

    it('should throw BadRequestException for non-pending request', async () => {
      mockPrisma.timeOffRequest.findUnique.mockResolvedValue({
        ...mockRequest,
        status: 'approved',
      });
      await expect(
        service.decide(1, { status: TimeOffRequestStatus.REJECTED }, 2),
      ).rejects.toThrow(BadRequestException);
    });
  });

  describe('delete', () => {
    it('should delete request', async () => {
      mockPrisma.timeOffRequest.findUnique.mockResolvedValue(mockRequest);
      mockPrisma.timeOffRequest.delete.mockResolvedValue(mockRequest);
      await service.delete(1);
      expect(mockPrisma.timeOffRequest.delete).toHaveBeenCalled();
    });
  });
});
