/**
 * Roles Decorator
 * Restricts access to specific user roles
 */
import { SetMetadata } from '@nestjs/common';

export const ROLES_KEY = 'roles';

/**
 * Restrict access to users with specified roles
 * @param roles - Array of allowed role names
 * @example @Roles('admin', 'manager') @Get('users') getUsers() {}
 */
export const Roles = (...roles: string[]) => SetMetadata(ROLES_KEY, roles);
