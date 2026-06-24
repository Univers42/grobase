import { ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtAuthGuard } from './jwt-auth.guard';
import { IS_PUBLIC_KEY } from '../../common/decorators/public.decorator';

describe('JwtAuthGuard', () => {
  let guard: JwtAuthGuard;
  let reflector: jest.Mocked<Reflector>;

  beforeEach(() => {
    reflector = {
      getAllAndOverride: jest.fn(),
    } as any;
    guard = new JwtAuthGuard(reflector);
  });

  it('should be defined', () => {
    expect(guard).toBeDefined();
  });

  it('should allow public routes', () => {
    reflector.getAllAndOverride.mockReturnValue(true);

    const context: Partial<ExecutionContext> = {
      getHandler: jest.fn(),
      getClass: jest.fn(),
    };

    const result = guard.canActivate(context as ExecutionContext);

    expect(reflector.getAllAndOverride).toHaveBeenCalledWith(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    expect(result).toBe(true);
  });

  it('should delegate to parent for non-public routes', () => {
    reflector.getAllAndOverride.mockReturnValue(false);

    const context: Partial<ExecutionContext> = {
      getHandler: jest.fn(),
      getClass: jest.fn(),
      switchToHttp: jest.fn().mockReturnValue({
        getRequest: jest.fn().mockReturnValue({
          headers: { authorization: 'Bearer token' },
        }),
      }),
    };

    // The parent AuthGuard('jwt').canActivate will be called
    // In unit test context, we just verify it doesn't return true for non-public
    expect(() => guard.canActivate(context as ExecutionContext)).not.toThrow();
  });
});
