/**
 * Auth Service - Part 2
 * Helper methods for auth operations
 */
import {
  Injectable,
  UnauthorizedException,
  NotFoundException,
} from '@nestjs/common';
import { PrismaService } from '../prisma';
import { PasswordService } from './password.service';
import { TokenService } from './token.service';

// This is a continuation - methods added to AuthService via partial class pattern
// In the actual implementation, merge with auth.service.ts

@Injectable()
export class AuthServiceHelpers {
  constructor(
    private readonly prisma: PrismaService,
    private readonly passwordService: PasswordService,
    private readonly tokenService: TokenService,
  ) {}

  async validateCredentials(email: string, password: string) {
    const user = await this.prisma.user.findUnique({
      where: { email },
      include: { Role: true },
    });

    if (!user) {
      throw new UnauthorizedException('Invalid credentials');
    }

    await this.passwordService.verify(password, user.password);
    return user;
  }

  async findUserById(userId: number) {
    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      include: { Role: true },
    });

    if (!user) {
      throw new NotFoundException('User not found');
    }

    return user;
  }

  async updateLastLogin(userId: number): Promise<void> {
    await this.prisma.user.update({
      where: { id: userId },
      data: { last_login_at: new Date() },
    });
  }

  generateAuthResponse(user: {
    id: number;
    email: string;
    first_name: string;
    Role: { name: string } | null;
  }) {
    const token = this.tokenService.generateAccessToken({
      sub: user.id,
      email: user.email,
      role: user.Role?.name ?? 'client',
    });

    return {
      accessToken: token,
      user: this.sanitizeUser(user),
    };
  }

  sanitizeUser(user: {
    id: number;
    email: string;
    first_name: string;
    last_name?: string | null;
    Role?: { name: string } | null;
  }) {
    return {
      id: user.id,
      email: user.email,
      firstName: user.first_name,
      lastName: user.last_name,
      role: user.Role?.name ?? 'client',
    };
  }
}
