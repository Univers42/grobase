import { ExecutionContext, ForbiddenException } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { RolesGuard } from './roles.guard';

describe('RolesGuard', () => {
  let guard: RolesGuard;
  let reflector: jest.Mocked<Reflector>;

  const createMockExecutionContext = (user?: {
    role: string;
  }): ExecutionContext => {
    return {
      switchToHttp: () => ({
        getRequest: () => ({ user }),
      }),
      getHandler: () => jest.fn(),
      getClass: () => jest.fn(),
    } as unknown as ExecutionContext;
  };

  beforeEach(() => {
    reflector = {
      getAllAndOverride: jest.fn(),
    } as unknown as jest.Mocked<Reflector>;
    guard = new RolesGuard(reflector);
  });

  describe('canActivate', () => {
    it('should allow access to public routes', () => {
      reflector.getAllAndOverride
        .mockReturnValueOnce(true) // IS_PUBLIC_KEY
        .mockReturnValueOnce(undefined); // ROLES_KEY

      const context = createMockExecutionContext();

      expect(guard.canActivate(context)).toBe(true);
    });

    it('should allow access when no roles are required', () => {
      reflector.getAllAndOverride
        .mockReturnValueOnce(false) // IS_PUBLIC_KEY
        .mockReturnValueOnce(undefined); // ROLES_KEY - no required roles

      const context = createMockExecutionContext({ role: 'client' });

      expect(guard.canActivate(context)).toBe(true);
    });

    it('should allow access when user has required role', () => {
      reflector.getAllAndOverride
        .mockReturnValueOnce(false) // IS_PUBLIC_KEY
        .mockReturnValueOnce(['admin', 'employee']); // ROLES_KEY

      const context = createMockExecutionContext({ role: 'admin' });

      expect(guard.canActivate(context)).toBe(true);
    });

    it('should throw ForbiddenException when user lacks required role', () => {
      reflector.getAllAndOverride
        .mockReturnValueOnce(false) // IS_PUBLIC_KEY
        .mockReturnValueOnce(['admin']); // ROLES_KEY

      const context = createMockExecutionContext({ role: 'client' });

      expect(() => guard.canActivate(context)).toThrow(ForbiddenException);
    });

    it('should throw ForbiddenException when user has no role', () => {
      reflector.getAllAndOverride
        .mockReturnValueOnce(false) // IS_PUBLIC_KEY
        .mockReturnValueOnce(['admin']); // ROLES_KEY

      const context = createMockExecutionContext({} as { role: string });

      expect(() => guard.canActivate(context)).toThrow(ForbiddenException);
    });

    it('should throw ForbiddenException when no user attached', () => {
      reflector.getAllAndOverride
        .mockReturnValueOnce(false) // IS_PUBLIC_KEY
        .mockReturnValueOnce(['admin']); // ROLES_KEY

      const context = createMockExecutionContext(undefined);

      expect(() => guard.canActivate(context)).toThrow(ForbiddenException);
    });

    it('should allow employee access to employee routes', () => {
      reflector.getAllAndOverride
        .mockReturnValueOnce(false)
        .mockReturnValueOnce(['employee', 'admin']);

      const context = createMockExecutionContext({ role: 'employee' });

      expect(guard.canActivate(context)).toBe(true);
    });
  });
});
