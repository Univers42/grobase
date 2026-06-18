/**
 * Consent Service Unit Tests
 */
import { Test, TestingModule } from '@nestjs/testing';
import { ConsentService } from './consent.service';
import { PrismaService } from '../prisma';
import { NotFoundException } from '@nestjs/common';
import { ConsentType } from './dto/gdpr.dto';

describe('ConsentService', () => {
  let service: ConsentService;

  const mockConsent = {
    id: 1,
    user_id: 1,
    consent_type: ConsentType.MARKETING,
    is_granted: true,
    granted_at: new Date(),
  };
  const mockPrisma = {
    userConsent: {
      findMany: jest.fn(),
      findFirst: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      updateMany: jest.fn(),
    },
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ConsentService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();
    service = module.get<ConsentService>(ConsentService);
    jest.clearAllMocks();
  });

  describe('getUserConsents', () => {
    it('should return all consents for user', async () => {
      mockPrisma.userConsent.findMany.mockResolvedValue([mockConsent]);
      const consents = await service.getUserConsents(1);
      expect(consents).toEqual([mockConsent]);
    });
  });

  describe('setUserConsent', () => {
    it('should create new consent', async () => {
      mockPrisma.userConsent.findFirst.mockResolvedValue(null);
      mockPrisma.userConsent.create.mockResolvedValue(mockConsent);
      await service.setUserConsent(1, {
        consent_type: ConsentType.MARKETING,
        consented: true,
      });
      expect(mockPrisma.userConsent.create).toHaveBeenCalled();
    });

    it('should update existing consent', async () => {
      mockPrisma.userConsent.findFirst.mockResolvedValue(mockConsent);
      mockPrisma.userConsent.update.mockResolvedValue({
        ...mockConsent,
        is_granted: false,
      });
      await service.setUserConsent(1, {
        consent_type: ConsentType.MARKETING,
        consented: false,
      });
      expect(mockPrisma.userConsent.update).toHaveBeenCalled();
    });
  });

  describe('updateConsent', () => {
    it('should throw NotFoundException when consent not found', async () => {
      mockPrisma.userConsent.findFirst.mockResolvedValue(null);
      await expect(
        service.updateConsent(1, 'marketing', { consented: false }),
      ).rejects.toThrow(NotFoundException);
    });
  });

  describe('withdrawAllConsents', () => {
    it('should revoke all non-essential consents', async () => {
      mockPrisma.userConsent.updateMany.mockResolvedValue({ count: 2 });
      await service.withdrawAllConsents(1);
      expect(mockPrisma.userConsent.updateMany).toHaveBeenCalled();
    });
  });
});
