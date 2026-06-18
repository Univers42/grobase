import { createParamDecorator, ExecutionContext } from '@nestjs/common';

/**
 * Extract the client's real IP address from the request
 * Handles X-Forwarded-For and other proxy headers
 */
export const ClientIp = createParamDecorator(
  (data: unknown, ctx: ExecutionContext): string => {
    const request = ctx.switchToHttp().getRequest();

    const forwardedFor = request.headers['x-forwarded-for'];
    if (forwardedFor) {
      const ips = typeof forwardedFor === 'string'
        ? forwardedFor.split(',')
        : forwardedFor;
      return ips[0].trim();
    }

    return (
      request.headers['x-real-ip'] ||
      request.connection?.remoteAddress ||
      request.ip ||
      '0.0.0.0'
    );
  },
);

/**
 * Extract user agent string from request
 */
export const UserAgent = createParamDecorator(
  (data: unknown, ctx: ExecutionContext): string => {
    const request = ctx.switchToHttp().getRequest();
    return request.headers['user-agent'] || 'Unknown';
  },
);

/**
 * Extract specific header value from request
 */
export const Header = createParamDecorator(
  (headerName: string, ctx: ExecutionContext): string | undefined => {
    const request = ctx.switchToHttp().getRequest();
    return request.headers[headerName.toLowerCase()];
  },
);
