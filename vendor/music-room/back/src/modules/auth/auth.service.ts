import {
  Injectable,
  ConflictException,
  UnauthorizedException,
  BadRequestException,
  NotFoundException,
} from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model } from 'mongoose';
import { JwtService } from '@nestjs/jwt';
import { ConfigService } from '@nestjs/config';
import * as bcrypt from 'bcrypt';
import { v4 as uuidv4 } from 'uuid';
import { User } from '../user/schemas/user.schema';
import { RegisterDto, LoginDto, RefreshTokenDto } from './dto';

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
}

@Injectable()
export class AuthService {
  constructor(
    @InjectModel(User.name) private readonly userModel: Model<User>,
    private readonly jwtService: JwtService,
    private readonly configService: ConfigService,
  ) {}

  // ─── Registration ────────────────────────────────────

  async register(dto: RegisterDto): Promise<{ message: string }> {
    const existing = await this.userModel.findOne({ email: dto.email });
    if (existing) {
      throw new ConflictException('Email already registered');
    }

    const passwordHash = await bcrypt.hash(dto.password, 12);
    const emailVerificationToken = uuidv4();
    const emailVerificationExpires = new Date(Date.now() + 24 * 60 * 60 * 1000); // 24h

    await this.userModel.create({
      email: dto.email,
      passwordHash,
      emailVerificationToken,
      emailVerificationExpires,
      publicInfo: { displayName: dto.displayName },
    });

    // TODO: Send verification email via EmailService
    return { message: 'Registration successful. Please verify your email.' };
  }

  // ─── Email Verification ──────────────────────────────

  async verifyEmail(token: string): Promise<{ message: string }> {
    const user = await this.userModel.findOne({
      emailVerificationToken: token,
      emailVerificationExpires: { $gt: new Date() },
    });

    if (!user) {
      throw new BadRequestException('Invalid or expired verification token');
    }

    user.isEmailVerified = true;
    user.emailVerificationToken = undefined;
    user.emailVerificationExpires = undefined;
    await user.save();

    return { message: 'Email verified successfully' };
  }

  // ─── Login ───────────────────────────────────────────

  async login(dto: LoginDto): Promise<TokenPair> {
    const user = await this.userModel.findOne({ email: dto.email });
    if (!user || !user.passwordHash) {
      throw new UnauthorizedException('Invalid email or password');
    }

    const isMatch = await bcrypt.compare(dto.password, user.passwordHash);
    if (!isMatch) {
      throw new UnauthorizedException('Invalid email or password');
    }

    if (!user.isEmailVerified) {
      throw new UnauthorizedException('Please verify your email before logging in');
    }

    return this.generateTokens(user);
  }

  // ─── Token Refresh ───────────────────────────────────

  async refreshTokens(dto: RefreshTokenDto): Promise<TokenPair> {
    let payload: { sub: string };
    try {
      payload = this.jwtService.verify(dto.refreshToken, {
        secret: this.configService.get<string>('JWT_REFRESH_SECRET'),
      });
    } catch {
      throw new UnauthorizedException('Invalid or expired refresh token');
    }

    const user = await this.userModel.findById(payload.sub);
    if (!user || !user.refreshTokenHash) {
      throw new UnauthorizedException('Invalid refresh token');
    }

    const isValid = await bcrypt.compare(dto.refreshToken, user.refreshTokenHash);
    if (!isValid) {
      // Possible token theft — invalidate all sessions
      user.refreshTokenHash = undefined;
      await user.save();
      throw new UnauthorizedException('Refresh token reuse detected. All sessions invalidated.');
    }

    return this.generateTokens(user);
  }

  // ─── Logout ──────────────────────────────────────────

  async logout(userId: string): Promise<{ message: string }> {
    await this.userModel.findByIdAndUpdate(userId, {
      $unset: { refreshTokenHash: 1 },
    });
    return { message: 'Logged out successfully' };
  }

  // ─── Forgot Password ────────────────────────────────

  async forgotPassword(email: string): Promise<{ message: string }> {
    const user = await this.userModel.findOne({ email });
    if (!user) {
      // Don't reveal if user exists
      return { message: 'If your email is registered, you will receive a password reset link.' };
    }

    user.passwordResetToken = uuidv4();
    user.passwordResetExpires = new Date(Date.now() + 60 * 60 * 1000); // 1h
    await user.save();

    // TODO: Send password reset email via EmailService
    return { message: 'If your email is registered, you will receive a password reset link.' };
  }

  // ─── Reset Password ─────────────────────────────────

  async resetPassword(token: string, newPassword: string): Promise<{ message: string }> {
    const user = await this.userModel.findOne({
      passwordResetToken: token,
      passwordResetExpires: { $gt: new Date() },
    });

    if (!user) {
      throw new BadRequestException('Invalid or expired password reset token');
    }

    user.passwordHash = await bcrypt.hash(newPassword, 12);
    user.passwordResetToken = undefined;
    user.passwordResetExpires = undefined;
    user.refreshTokenHash = undefined; // Invalidate all sessions
    await user.save();

    return { message: 'Password reset successfully' };
  }

  // ─── Social Auth: Google ─────────────────────────────

  async validateGoogleUser(profile: {
    googleId: string;
    email: string;
    displayName: string;
    avatar?: string;
  }): Promise<TokenPair> {
    let user = await this.userModel.findOne({
      $or: [{ googleId: profile.googleId }, { email: profile.email }],
    });

    if (user) {
      // Link Google if not already linked
      if (!user.googleId) {
        user.googleId = profile.googleId;
        if (!user.linkedAccounts.includes('google')) {
          user.linkedAccounts.push('google');
        }
        await user.save();
      }
    } else {
      // Create new user
      user = await this.userModel.create({
        email: profile.email,
        googleId: profile.googleId,
        isEmailVerified: true, // Google emails are pre-verified
        linkedAccounts: ['google'],
        publicInfo: {
          displayName: profile.displayName,
          avatar: profile.avatar || '',
        },
      });
    }

    return this.generateTokens(user);
  }

  // ─── Social Auth: Facebook ───────────────────────────

  async validateFacebookUser(profile: {
    facebookId: string;
    email: string;
    displayName: string;
    avatar?: string;
  }): Promise<TokenPair> {
    let user = await this.userModel.findOne({
      $or: [{ facebookId: profile.facebookId }, { email: profile.email }],
    });

    if (user) {
      if (!user.facebookId) {
        user.facebookId = profile.facebookId;
        if (!user.linkedAccounts.includes('facebook')) {
          user.linkedAccounts.push('facebook');
        }
        await user.save();
      }
    } else {
      user = await this.userModel.create({
        email: profile.email,
        facebookId: profile.facebookId,
        isEmailVerified: true,
        linkedAccounts: ['facebook'],
        publicInfo: {
          displayName: profile.displayName,
          avatar: profile.avatar || '',
        },
      });
    }

    return this.generateTokens(user);
  }

  // ─── Link Social Account ────────────────────────────

  async linkGoogle(userId: string, googleId: string): Promise<{ message: string }> {
    const existingUser = await this.userModel.findOne({ googleId });
    if (existingUser && existingUser._id.toString() !== userId) {
      throw new ConflictException('This Google account is already linked to another user');
    }

    await this.userModel.findByIdAndUpdate(userId, {
      googleId,
      $addToSet: { linkedAccounts: 'google' },
    });

    return { message: 'Google account linked successfully' };
  }

  async linkFacebook(userId: string, facebookId: string): Promise<{ message: string }> {
    const existingUser = await this.userModel.findOne({ facebookId });
    if (existingUser && existingUser._id.toString() !== userId) {
      throw new ConflictException('This Facebook account is already linked to another user');
    }

    await this.userModel.findByIdAndUpdate(userId, {
      facebookId,
      $addToSet: { linkedAccounts: 'facebook' },
    });

    return { message: 'Facebook account linked successfully' };
  }

  // ─── Token Generation (Private) ─────────────────────

  private async generateTokens(user: User): Promise<TokenPair> {
    const payload = { sub: user._id, email: user.email };

    const accessToken = this.jwtService.sign(payload, {
      secret: this.configService.get<string>('JWT_SECRET'),
      expiresIn: this.configService.get<string>('JWT_EXPIRATION', '15m'),
    });

    const refreshToken = this.jwtService.sign(payload, {
      secret: this.configService.get<string>('JWT_REFRESH_SECRET'),
      expiresIn: this.configService.get<string>('JWT_REFRESH_EXPIRATION', '7d'),
    });

    // Store hashed refresh token (single-use rotation)
    user.refreshTokenHash = await bcrypt.hash(refreshToken, 10);
    await user.save();

    return { accessToken, refreshToken };
  }
}
