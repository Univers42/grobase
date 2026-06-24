import { Test, TestingModule } from '@nestjs/testing';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';

describe('AuthController', () => {
  let controller: AuthController;
  let authService: jest.Mocked<Partial<AuthService>>;

  beforeEach(async () => {
    authService = {
      register: jest.fn(),
      login: jest.fn(),
      refreshTokens: jest.fn(),
      logout: jest.fn(),
      forgotPassword: jest.fn(),
      resetPassword: jest.fn(),
      verifyEmail: jest.fn(),
    };

    const module: TestingModule = await Test.createTestingModule({
      controllers: [AuthController],
      providers: [{ provide: AuthService, useValue: authService }],
    }).compile();

    controller = module.get<AuthController>(AuthController);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  describe('register', () => {
    it('should call authService.register with dto', async () => {
      const dto = { email: 'test@test.com', password: 'Pass123!', username: 'test' };
      authService.register.mockResolvedValue({ message: 'ok' } as any);

      const result = await controller.register(dto as any);

      expect(authService.register).toHaveBeenCalledWith(dto);
      expect(result).toEqual({ message: 'ok' });
    });
  });

  describe('login', () => {
    it('should call authService.login with correct params', async () => {
      const dto = { email: 'test@test.com', password: 'Pass123!' };
      const tokens = { accessToken: 'at', refreshToken: 'rt', user: {} };
      authService.login.mockResolvedValue(tokens as any);

      const result = await controller.login(dto as any);

      expect(authService.login).toHaveBeenCalledWith(dto.email, dto.password);
      expect(result).toEqual(tokens);
    });
  });

  describe('refreshTokens', () => {
    it('should call authService.refreshTokens', async () => {
      const dto = { refreshToken: 'old-rt' };
      const user = { _id: 'user1' };
      const tokens = { accessToken: 'new-at', refreshToken: 'new-rt' };
      authService.refreshTokens.mockResolvedValue(tokens as any);

      const result = await controller.refreshTokens(user as any, dto as any);

      expect(authService.refreshTokens).toHaveBeenCalledWith('user1', 'old-rt');
      expect(result).toEqual(tokens);
    });
  });

  describe('logout', () => {
    it('should call authService.logout with user id', async () => {
      const user = { _id: 'user1' };
      authService.logout.mockResolvedValue(undefined);

      await controller.logout(user as any);

      expect(authService.logout).toHaveBeenCalledWith('user1');
    });
  });

  describe('forgotPassword', () => {
    it('should call authService.forgotPassword with email', async () => {
      const dto = { email: 'test@test.com' };
      authService.forgotPassword.mockResolvedValue(undefined);

      await controller.forgotPassword(dto as any);

      expect(authService.forgotPassword).toHaveBeenCalledWith('test@test.com');
    });
  });

  describe('resetPassword', () => {
    it('should call authService.resetPassword with token and password', async () => {
      const dto = { token: 'reset-token', newPassword: 'NewPass123!' };
      authService.resetPassword.mockResolvedValue(undefined);

      await controller.resetPassword(dto as any);

      expect(authService.resetPassword).toHaveBeenCalledWith('reset-token', 'NewPass123!');
    });
  });
});
