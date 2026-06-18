/**
 * User Session Service Unit Tests
 */
import { Test, TestingModule } from '@nestjs/testing';
import { UserSessionService } from './user-session.service';
import { PrismaService } from '../prisma';
import { ForbiddenException } from '@nestjs/common';

describe('UserSessionService', () => {
  let service: UserSessionService;

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
      create: jest.fn(),
      update: jest.fn(),
      delete: jest.fn(),
      deleteMany: jest.fn(),
    },
  };

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        UserSessionService,
        { provide: PrismaService, useValue: mockPrisma },
      ],
    }).compile();
    service = module.get<UserSessionService>(UserSessionService);
    jest.clearAllMocks();
  });

  describe('create', () => {
    it('should create session', async () => {
      mockPrisma.userSession.create.mockResolvedValue(mockSession);
      const result = await service.create(1, {
        token: 'token123',
        device_info: 'Chrome',
        ip_address: '127.0.0.1',
      });
      expect(result).toEqual(mockSession);
    });
  });

  describe('validate', () => {
    it('should return valid for active session', async () => {
      mockPrisma.userSession.findUnique.mockResolvedValue(mockSession);
      const result = await service.validate('token123');
      expect(result.valid).toBe(true);
    });

    it('should return invalid for expired session', async () => {
      mockPrisma.userSession.findUnique.mockResolvedValue({
        ...mockSession,
        expires_at: new Date(Date.now() - 1000),
      });
      const result = await service.validate('token123');
      expect(result.valid).toBe(false);
    });
  });

  describe('revoke', () => {
    it('should revoke own session', async () => {
      mockPrisma.userSession.findUnique.mockResolvedValue(mockSession);
      mockPrisma.userSession.delete.mockResolvedValue(mockSession);
      await service.revoke(1, 1);
      expect(mockPrisma.userSession.delete).toHaveBeenCalled();
    });

    it('should throw ForbiddenException for other user session', async () => {
      mockPrisma.userSession.findUnique.mockResolvedValue({
        ...mockSession,
        user_id: 99,
      });
      await expect(service.revoke(1, 1)).rejects.toThrow(ForbiddenException);
    });
  });
});
