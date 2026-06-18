/**
 * Admin Session Service Unit Tests
 */
import { Test, TestingModule } from '@nestjs/testing';
import { AdminSessionService } from './admin-session.service';
import { PrismaService } from '../prisma';
import { NotFoundException } from '@nestjs/common';

describe('AdminSessionService', () => {
  let service: AdminSessionService;

  const mockSession = {
    id: 1,
    user_id: 1,
    session_token: 'token123',
    expires_at: new Date(Date.now() + 86400000),
  };
  const mockPrisma = {
    userSession: {
      findUnique: jest.fn(),
      findMany: jest.fn(),
      count: jest.fn(),
      groupBy: jest.fn(),
      delete: jest.fn(),
      deleteMany: jest.fn(),
    },
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        AdminSessionService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();
    service = module.get<AdminSessionService>(AdminSessionService);
    jest.clearAllMocks();
  });

  describe('cleanupExpired', () => {
    it('should delete expired sessions', async () => {
      mockPrisma.userSession.deleteMany.mockResolvedValue({ count: 5 });
      const result = await service.cleanupExpired();
      expect(result.deletedCount).toBe(5);
    });
  });

  describe('getStats', () => {
    it('should return session statistics', async () => {
      mockPrisma.userSession.count
        .mockResolvedValueOnce(100)
        .mockResolvedValueOnce(80);
      mockPrisma.userSession.groupBy.mockResolvedValue([
        { user_id: 1 },
        { user_id: 2 },
      ]);
      const result = await service.getStats();
      expect(result.total).toBe(100);
      expect(result.active).toBe(80);
      expect(result.usersWithActiveSessions).toBe(2);
    });
  });

  describe('forceRevoke', () => {
    it('should revoke session', async () => {
      mockPrisma.userSession.findUnique.mockResolvedValue(mockSession);
      mockPrisma.userSession.delete.mockResolvedValue(mockSession);
      await service.forceRevoke(1);
      expect(mockPrisma.userSession.delete).toHaveBeenCalled();
    });

    it('should throw NotFoundException when not found', async () => {
      mockPrisma.userSession.findUnique.mockResolvedValue(null);
      await expect(service.forceRevoke(999)).rejects.toThrow(NotFoundException);
    });
  });
});
