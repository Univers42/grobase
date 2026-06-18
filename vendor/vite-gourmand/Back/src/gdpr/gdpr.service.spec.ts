/**
 * GDPR Service Unit Tests
 */
import { Test, TestingModule } from '@nestjs/testing';
import { GdprService } from './gdpr.service';
import { ConsentService } from './consent.service';
import { DataDeletionService } from './data-deletion.service';
import { PrismaService } from '../prisma';
import { NotFoundException } from '@nestjs/common';

describe('GdprService', () => {
  let service: GdprService;
  let consentService: jest.Mocked<ConsentService>;
  let deletionService: jest.Mocked<DataDeletionService>;

  const mockPrisma = {
    user: { findUnique: jest.fn() },
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        GdprService,
        { provide: PrismaService, useValue: mockPrisma },
        {
          provide: ConsentService,
          useValue: { getUserConsents: jest.fn(), setUserConsent: jest.fn() },
        },
        {
          provide: DataDeletionService,
          useValue: { createRequest: jest.fn(), cancelRequest: jest.fn() },
        },
      ],
    }).compile();
    service = module.get<GdprService>(GdprService);
    consentService = module.get(ConsentService);
    deletionService = module.get(DataDeletionService);
    jest.clearAllMocks();
  });

  describe('facade delegation', () => {
    it('should delegate getUserConsents to ConsentService', async () => {
      await service.getUserConsents(1);
      expect(consentService.getUserConsents).toHaveBeenCalledWith(1);
    });

    it('should delegate createDeletionRequest to DataDeletionService', async () => {
      await service.createDeletionRequest(1, { reason: 'test' });
      expect(deletionService.createRequest).toHaveBeenCalledWith(1, {
        reason: 'test',
      });
    });
  });

  describe('exportUserData', () => {
    it('should export user data', async () => {
      const mockUser = {
        id: 1,
        email: 'test@test.com',
        password: 'hashed',
        UserAddress: [],
        Order: [],
      };
      mockPrisma.user.findUnique.mockResolvedValue(mockUser);
      const result = await service.exportUserData(1);
      expect(result.data.email).toBe('test@test.com');
      expect(result.data).not.toHaveProperty('password');
    });

    it('should throw NotFoundException when user not found', async () => {
      mockPrisma.user.findUnique.mockResolvedValue(null);
      await expect(service.exportUserData(999)).rejects.toThrow(
        NotFoundException,
      );
    });
  });
});
