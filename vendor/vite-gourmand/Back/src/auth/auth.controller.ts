/**
 * Auth Controller
 * Handles authentication endpoints
 */
import {
  Controller,
  Post,
  Get,
  Body,
  HttpCode,
  HttpStatus,
  UseGuards,
  Req,
  Res,
} from '@nestjs/common';
import { Response } from 'express';
import { randomBytes } from 'node:crypto';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { ConfigService } from '@nestjs/config';
import { AuthService } from './auth.service';
import { Public, CurrentUser, JwtPayload } from '../common';
import { AuthGuard } from '@nestjs/passport';
import { RegisterDto } from './dto/register.dto';
import { LoginDto } from './dto/login.dto';
import {
  ChangePasswordDto,
  ForgotPasswordDto,
  ResetPasswordDto,
} from './dto/password.dto';
import {
  AUTH_COOKIE_MAX_AGE_MS,
  AUTH_COOKIE_NAME,
  AUTH_CSRF_COOKIE_NAME,
} from './auth-cookie.constants';

interface AuthResult {
  accessToken: string;
  user: unknown;
}

@ApiTags('auth')
@Controller('auth')
export class AuthController {
  constructor(
    private readonly authService: AuthService,
    private readonly configService: ConfigService,
  ) {}

  @Public()
  @Post('register')
  @ApiOperation({ summary: 'Register a new user' })
  async register(
    @Body() dto: RegisterDto,
    @Res({ passthrough: true }) res: Response,
  ) {
    const authResult = await this.authService.register(dto);
    return this.completeBrowserSession(res, authResult);
  }

  @Public()
  @Post('login')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Login with email and password' })
  async login(
    @Body() dto: LoginDto,
    @Res({ passthrough: true }) res: Response,
  ) {
    const authResult = await this.authService.login(dto);
    return this.completeBrowserSession(res, authResult);
  }

  @Public()
  @Post('logout')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Clear browser authentication cookie' })
  logout(@Res({ passthrough: true }) res: Response) {
    this.clearAuthCookie(res);
    return { message: 'Logged out' };
  }

  @Get('me')
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Get current user profile' })
  async getProfile(@CurrentUser() user: JwtPayload) {
    return this.authService.getProfile(user.sub);
  }

  @Public()
  @Post('forgot-password')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Request password reset email' })
  async forgotPassword(@Body() dto: ForgotPasswordDto) {
    return this.authService.forgotPassword(dto.email);
  }

  @Public()
  @Post('verify-reset-token')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({
    summary: 'Verify if a password reset token is valid (without consuming it)',
  })
  async verifyResetToken(@Body() body: { token?: string }) {
    const token = body.token;
    if (!token) {
      return { valid: false, message: 'Token is required' };
    }
    return this.authService.verifyResetToken(token);
  }

  @Public()
  @Get('verify-reset-token')
  @ApiOperation({
    summary:
      'Verify if a password reset token is valid (legacy query endpoint)',
  })
  async verifyResetTokenLegacy(@Req() req: { query: { token?: string } }) {
    const token = req.query.token;
    if (!token) {
      return { valid: false, message: 'Token is required' };
    }
    return this.authService.verifyResetToken(token);
  }

  @Public()
  @Post('reset-password')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Reset password with token' })
  async resetPassword(@Body() dto: ResetPasswordDto) {
    return this.authService.resetPassword(dto.token, dto.newPassword);
  }

  @Post('change-password')
  @ApiBearerAuth()
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Change password (authenticated)' })
  async changePassword(
    @CurrentUser() user: JwtPayload,
    @Body() dto: ChangePasswordDto,
  ) {
    return this.authService.changePassword(
      user.sub,
      dto.currentPassword,
      dto.newPassword,
    );
  }

  @Public()
  @Get('google')
  @UseGuards(AuthGuard('google'))
  @ApiOperation({ summary: 'Initiate Google OAuth login' })
  googleLogin() {
    // Redirects to Google
  }

  @Public()
  @Get('google/callback')
  @UseGuards(AuthGuard('google'))
  @ApiOperation({ summary: 'Google OAuth callback' })
  async googleCallback(
    @Req() req: { user: { email: string; name: string } },
    @Res({ passthrough: true }) res: Response,
  ) {
    const authResult = await this.authService.googleLogin(req.user);
    return this.completeBrowserSession(res, authResult);
  }

  @Public()
  @Get('google/config')
  @ApiOperation({ summary: 'Get Google OAuth client configuration' })
  getGoogleConfig() {
    const clientId = this.configService.get<string>('GOOGLE_CLIENT_ID');
    return { clientId: clientId || null };
  }

  @Public()
  @Post('google/token')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Login with Google ID token (from frontend GSI)' })
  async googleToken(
    @Body() body: { credential: string },
    @Res({ passthrough: true }) res: Response,
  ) {
    const authResult = await this.authService.googleTokenLogin(body.credential);
    return this.completeBrowserSession(res, authResult);
  }

  private completeBrowserSession(res: Response, authResult: AuthResult) {
    if (process.env.NODE_ENV === 'test') {
      return authResult;
    }

    this.setAuthCookie(res, authResult.accessToken);
    this.setCsrfCookie(res, this.createCsrfToken());
    return { user: authResult.user };
  }

  private setAuthCookie(res: Response, token: string): void {
    res.cookie(AUTH_COOKIE_NAME, token, {
      httpOnly: true,
      secure: this.shouldUseSecureCookies(),
      sameSite: 'lax',
      path: '/',
      maxAge: AUTH_COOKIE_MAX_AGE_MS,
    });
  }

  private clearAuthCookie(res: Response): void {
    res.clearCookie(AUTH_COOKIE_NAME, {
      httpOnly: true,
      secure: this.shouldUseSecureCookies(),
      sameSite: 'lax',
      path: '/',
    });
    res.clearCookie(AUTH_CSRF_COOKIE_NAME, {
      httpOnly: false,
      secure: this.shouldUseSecureCookies(),
      sameSite: 'lax',
      path: '/',
    });
  }

  private setCsrfCookie(res: Response, token: string): void {
    res.cookie(AUTH_CSRF_COOKIE_NAME, token, {
      httpOnly: false,
      secure: this.shouldUseSecureCookies(),
      sameSite: 'lax',
      path: '/',
      maxAge: AUTH_COOKIE_MAX_AGE_MS,
    });
  }

  private createCsrfToken(): string {
    return randomBytes(32).toString('base64url');
  }

  private shouldUseSecureCookies(): boolean {
    return (
      this.configService.get<string>('COOKIE_SECURE') === 'true' ||
      this.configService.get<string>('NODE_ENV') === 'production'
    );
  }
}
