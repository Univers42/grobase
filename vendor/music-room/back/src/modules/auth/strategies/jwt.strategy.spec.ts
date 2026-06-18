import { JwtStrategy } from './jwt.strategy';
import { UnauthorizedException } from '@nestjs/common';

describe('JwtStrategy', () => {
  let strategy: JwtStrategy;
  let userModel: any;

  beforeEach(() => {
    userModel = {
      findById: jest.fn(),
    };

    // Use a mock ConfigService
    const configService = {
      get: jest.fn().mockReturnValue('test-jwt-secret'),
    };

    strategy = new JwtStrategy(configService as any, userModel);
  });

  it('should be defined', () => {
    expect(strategy).toBeDefined();
  });

  describe('validate', () => {
    it('should return user when found', async () => {
      const user = { _id: 'user1', email: 'test@test.com' };
      userModel.findById.mockReturnValue({
        select: jest.fn().mockResolvedValue(user),
      });

      const result = await strategy.validate({ sub: 'user1' });

      expect(userModel.findById).toHaveBeenCalledWith('user1');
      expect(result).toEqual(user);
    });

    it('should throw UnauthorizedException when user not found', async () => {
      userModel.findById.mockReturnValue({
        select: jest.fn().mockResolvedValue(null),
      });

      await expect(strategy.validate({ sub: 'invalid' })).rejects.toThrow(
        UnauthorizedException,
      );
    });
  });
});
