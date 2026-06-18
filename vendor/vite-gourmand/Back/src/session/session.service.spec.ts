/**
 * Session Service Unit Tests (Facade)
 */
import { Test, TestingModule } from '@nestjs/testing';
import { SessionService } from './session.service';
import { UserSessionService } from './user-session.service';
import { AdminSessionService } from './admin-session.service';

describe('SessionService', () => {
  let service: SessionService;
  let userSessionService: jest.Mocked<UserSessionService>;
  let adminSessionService: jest.Mocked<AdminSessionService>;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        SessionService,
        {
          provide: UserSessionService,
          useValue: {
            create: jest.fn(),
            validate: jest.fn(),
            revoke: jest.fn(),
          },
        },
        {
          provide: AdminSessionService,
          useValue: {
            getStats: jest.fn(),
            cleanupExpired: jest.fn(),
            forceRevoke: jest.fn(),
          },
        },
      ],
    }).compile();
    service = module.get<SessionService>(SessionService);
    userSessionService = module.get(UserSessionService);
    adminSessionService = module.get(AdminSessionService);
    jest.clearAllMocks();
  });

  describe('delegation', () => {
    it('should delegate createSession to UserSessionService', async () => {
      const dto = {
        token: 'tok',
        device_info: 'Chrome',
        ip_address: '127.0.0.1',
      };
      await service.createSession(1, dto);
      expect(userSessionService.create).toHaveBeenCalledWith(1, dto);
    });

    it('should delegate validateSession to UserSessionService', async () => {
      await service.validateSession('token123');
      expect(userSessionService.validate).toHaveBeenCalledWith('token123');
    });

    it('should delegate getSessionStats to AdminSessionService', async () => {
      await service.getSessionStats();
      expect(adminSessionService.getStats).toHaveBeenCalled();
    });

    it('should delegate cleanupExpiredSessions to AdminSessionService', async () => {
      await service.cleanupExpiredSessions();
      expect(adminSessionService.cleanupExpired).toHaveBeenCalled();
    });
  });
});
