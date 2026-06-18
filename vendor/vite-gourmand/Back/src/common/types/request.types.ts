/**
 * Request Types
 * Typed request interfaces for authenticated routes
 */
import { Request } from 'express';

export interface JwtPayload {
  sub: number;
  email: string;
  role: string;
  iat?: number;
  exp?: number;
}

export interface AuthenticatedRequest extends Request {
  user: JwtPayload;
}

export interface OptionalAuthRequest extends Omit<Request, 'user'> {
  user?: JwtPayload | null;
}
