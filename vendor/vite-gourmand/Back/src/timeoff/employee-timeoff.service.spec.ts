/**
 * Employee Time Off Service Unit Tests
 */
import { Test, TestingModule } from '@nestjs/testing';
import { EmployeeTimeOffService } from './employee-timeoff.service';
import { PrismaService } from '../prisma';
import { BadRequestException, ForbiddenException } from '@nestjs/common';
import { TimeOffRequestType } from './dto/timeoff.dto';

describe('EmployeeTimeOffService', () => {
  let service: EmployeeTimeOffService;

  const mockRequest = {
    id: 1,
    user_id: 1,
    status: 'pending',
    start_date: new Date(),
    end_date: new Date(),
  };
  const mockPrisma = {
    timeOffRequest: {
      findFirst: jest.fn(),
      findUnique: jest.fn(),
      findMany: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
    },
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        EmployeeTimeOffService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();
    service = module.get<EmployeeTimeOffService>(EmployeeTimeOffService);
    jest.clearAllMocks();
  });

  describe('create', () => {
    it('should create request', async () => {
      mockPrisma.timeOffRequest.findFirst.mockResolvedValue(null);
      mockPrisma.timeOffRequest.create.mockResolvedValue(mockRequest);
      const result = await service.create(
        {
          request_type: TimeOffRequestType.VACATION,
          start_date: '2024-01-10',
          end_date: '2024-01-15',
          reason: 'test',
        },
        1,
      );
      expect(result).toEqual(mockRequest);
    });

    it('should throw BadRequestException for invalid dates', async () => {
      await expect(
        service.create(
          {
            request_type: TimeOffRequestType.VACATION,
            start_date: '2024-01-15',
            end_date: '2024-01-10',
          },
          1,
        ),
      ).rejects.toThrow(BadRequestException);
    });
  });

  describe('cancel', () => {
    it('should cancel pending request', async () => {
      mockPrisma.timeOffRequest.findUnique.mockResolvedValue(mockRequest);
      mockPrisma.timeOffRequest.update.mockResolvedValue({
        ...mockRequest,
        status: 'cancelled',
      });
      await service.cancel(1, 1);
      expect(mockPrisma.timeOffRequest.update).toHaveBeenCalled();
    });

    it('should throw ForbiddenException for other user request', async () => {
      mockPrisma.timeOffRequest.findUnique.mockResolvedValue({
        ...mockRequest,
        user_id: 99,
      });
      await expect(service.cancel(1, 1)).rejects.toThrow(ForbiddenException);
    });
  });
});
