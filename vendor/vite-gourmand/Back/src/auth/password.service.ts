/**
 * Password Service
 * Handles password hashing and verification
 */
import { Injectable, UnauthorizedException } from '@nestjs/common';
import * as bcrypt from 'bcrypt';

const SALT_ROUNDS = 12;

@Injectable()
export class PasswordService {
  /**
   * Hash a plain text password
   */
  async hash(password: string): Promise<string> {
    return bcrypt.hash(password, SALT_ROUNDS);
  }

  /**
   * Verify password against hash
   * @throws UnauthorizedException if password doesn't match
   */
  async verify(password: string, hash: string): Promise<void> {
    const isValid = await bcrypt.compare(password, hash);
    if (!isValid) {
      throw new UnauthorizedException('Invalid credentials');
    }
  }

  /**
   * Check if password meets minimum requirements
   */
  validateStrength(password: string): { valid: boolean; errors: string[] } {
    const errors: string[] = [];

    if (password.length < 8) {
      errors.push('Password must be at least 8 characters');
    }
    if (!/[A-Z]/.test(password)) {
      errors.push('Password must contain uppercase letter');
    }
    if (!/[a-z]/.test(password)) {
      errors.push('Password must contain lowercase letter');
    }
    if (!/\d/.test(password)) {
      errors.push('Password must contain a number');
    }

    return { valid: errors.length === 0, errors };
  }
}
