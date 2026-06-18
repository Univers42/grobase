/**
 * Public Decorator
 * Marks routes as publicly accessible (no auth required)
 */
import { SetMetadata } from '@nestjs/common';

export const IS_PUBLIC_KEY = 'isPublic';

/**
 * Mark a route or controller as public (no authentication required)
 * @example @Public() @Get('health') healthCheck() {}
 */
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);
