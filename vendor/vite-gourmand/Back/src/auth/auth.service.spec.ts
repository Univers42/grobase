import { Test, TestingModule } from '@nestjs/testing';
import {
  UnauthorizedException,
  NotFoundException,
  ConflictException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { AuthService } from './auth.service';
import { PrismaService } from '../prisma';
import { PasswordService } from './password.service';
import { TokenService } from './token.service';
import { MailService } from '../mail/mail.service';
import { NewsletterService } from '../newsletter/newsletter.service';

describe('AuthService', () => {
  let service: AuthService;
  let prisma: jest.Mocked<PrismaService>;
  let passwordService: jest.Mocked<PasswordService>;
  let tokenService: jest.Mocked<TokenService>;

  const mockUser = {
    id: 1,
    email: 'test@example.com',
    password: 'hashedPassword',
    first_name: 'John',
    last_name: 'Doe',
    is_active: true,
    is_deleted: false,
    Role: { id: 2, name: 'client' },
  };

  beforeEach(async () => {
    const mockPrisma = {
      user: {
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
      },
    };

    const mockPasswordService = {
      hash: jest.fn().mockResolvedValue('hashedPassword'),
      verify: jest.fn().mockResolvedValue(undefined),
    };

    const mockTokenService = {
      generateAccessToken: jest.fn().mockReturnValue('mock-token'),
      createPasswordResetToken: jest.fn().mockResolvedValue('reset-token'),
      validatePasswordResetToken: jest.fn().mockResolvedValue(1),
    };

    const mockConfigService = {
      get: jest.fn((key: string, defaultValue?: string) => {
        const config: Record<string, string> = {
          GOOGLE_CLIENT_ID: 'test-google-client-id',
          FRONTEND_URL: 'http://localhost:5173',
        };
        return config[key] ?? defaultValue;
      }),
    };

    const mockMailService = {
      send: jest.fn().mockResolvedValue(true),
      sendPasswordReset: jest.fn().mockResolvedValue(true),
      sendOrderConfirmation: jest.fn().mockResolvedValue(true),
    };

    const mockNewsletterService = {
      subscribe: jest.fn().mockResolvedValue({ message: 'ok' }),
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        AuthService,
        { provide: PrismaService, useValue: mockPrisma },
        { provide: PasswordService, useValue: mockPasswordService },
        { provide: TokenService, useValue: mockTokenService },
        { provide: ConfigService, useValue: mockConfigService },
        { provide: MailService, useValue: mockMailService },
        { provide: NewsletterService, useValue: mockNewsletterService },
      ],
    }).compile();

    service = module.get<AuthService>(AuthService);
    prisma = module.get(PrismaService);
    passwordService = module.get(PasswordService);
    tokenService = module.get(TokenService);
  });

  describe('register', () => {
    it('should register a new user', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(null);
      (prisma.user.create as jest.Mock).mockResolvedValue(mockUser);

      const result = await service.register({
        email: 'new@test.com',
        password: 'password123',
        firstName: 'Jane',
        gdprConsent: true,
      });

      expect(result).toHaveProperty('accessToken');
      expect(result).toHaveProperty('user');
      expect(passwordService.hash).toHaveBeenCalled();
    });

    it('should throw if email already exists', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockUser);

      await expect(
        service.register({
          email: 'test@example.com',
          password: 'password',
          firstName: 'Test',
          gdprConsent: true,
        }),
      ).rejects.toThrow(ConflictException);
    });
  });

  describe('login', () => {
    it('should login with valid credentials', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockUser);
      (prisma.user.update as jest.Mock).mockResolvedValue(mockUser);

      const result = await service.login({
        email: 'test@example.com',
        password: 'password',
      });

      expect(result).toHaveProperty('accessToken');
      expect(tokenService.generateAccessToken).toHaveBeenCalled();
    });

    it('should throw on invalid email', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(
        service.login({ email: 'wrong@email.com', password: 'password' }),
      ).rejects.toThrow(UnauthorizedException);
    });

    it('should throw on invalid password', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockUser);
      (passwordService.verify as jest.Mock).mockRejectedValue(
        new UnauthorizedException('Invalid credentials'),
      );

      await expect(
        service.login({ email: 'test@example.com', password: 'wrong' }),
      ).rejects.toThrow(UnauthorizedException);
    });
  });

  describe('getProfile', () => {
    it('should return user profile', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockUser);

      const result = await service.getProfile(1);

      expect(result.email).toBe('test@example.com');
      expect(result.firstName).toBe('John');
    });

    it('should throw if user not found', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(null);

      await expect(service.getProfile(999)).rejects.toThrow(NotFoundException);
    });
  });

  describe('forgotPassword', () => {
    it('should initiate password reset for existing user', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockUser);

      const result = await service.forgotPassword('test@example.com');

      expect(result.message).toContain('email exists');
      expect(tokenService.createPasswordResetToken).toHaveBeenCalledWith(1);
    });

    it('should not throw for non-existent email (security)', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(null);

      const result = await service.forgotPassword('nonexistent@test.com');

      expect(result).toHaveProperty('message');
    });
  });

  describe('resetPassword', () => {
    it('should reset password with valid token', async () => {
      (prisma.user.update as jest.Mock).mockResolvedValue(mockUser);

      const result = await service.resetPassword('valid-token', 'newPassword');

      expect(result.message).toContain('successful');
      expect(passwordService.hash).toHaveBeenCalledWith('newPassword');
    });
  });

  describe('changePassword', () => {
    it('should change password with correct current password', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockUser);
      (prisma.user.update as jest.Mock).mockResolvedValue(mockUser);

      const result = await service.changePassword(1, 'oldPass', 'newPass');

      expect(result.message).toContain('changed');
      expect(passwordService.verify).toHaveBeenCalled();
    });

    it('should throw on incorrect current password', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockUser);
      (passwordService.verify as jest.Mock).mockRejectedValue(
        new UnauthorizedException('Invalid credentials'),
      );

      await expect(
        service.changePassword(1, 'wrongPass', 'newPass'),
      ).rejects.toThrow(UnauthorizedException);
    });
  });

  describe('googleLogin', () => {
    it('should login existing Google user', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(mockUser);

      const result = await service.googleLogin({
        email: 'test@example.com',
        name: 'John Doe',
      });

      expect(result).toHaveProperty('accessToken');
    });

    it('should create new user for Google login', async () => {
      (prisma.user.findUnique as jest.Mock).mockResolvedValue(null);
      (prisma.user.create as jest.Mock).mockResolvedValue(mockUser);

      const result = await service.googleLogin({
        email: 'google@test.com',
        name: 'Google User',
      });

      expect(result).toHaveProperty('accessToken');
      expect(prisma.user.create).toHaveBeenCalled();
    });
  });
});
