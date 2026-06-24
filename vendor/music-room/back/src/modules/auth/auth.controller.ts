import {
  Controller,
  Post,
  Get,
  Body,
  Query,
  Req,
  UseGuards,
  HttpCode,
  HttpStatus,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiResponse, ApiBearerAuth } from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import { AuthService, TokenPair } from './auth.service';
import {
  RegisterDto,
  LoginDto,
  RefreshTokenDto,
  ForgotPasswordDto,
  ResetPasswordDto,
  SocialAuthDto,
} from './dto';
import { GoogleAuthGuard } from './guards/google-auth.guard';
import { FacebookAuthGuard } from './guards/facebook-auth.guard';
import { Public } from '../../common/decorators/public.decorator';
import { CurrentUser } from '../../common/decorators/current-user.decorator';

@ApiTags('auth')
@Controller('auth')
export class AuthController {
  constructor(private readonly authService: AuthService) {}

  // ─── Local Auth ──────────────────────────────────────

  @Public()
  @Post('register')
  @ApiOperation({ summary: 'Register a new account with email/password' })
  @ApiResponse({ status: 201, description: 'Registration successful' })
  @ApiResponse({ status: 409, description: 'Email already registered' })
  async register(@Body() dto: RegisterDto) {
    return this.authService.register(dto);
  }

  @Public()
  @Post('login')
  @HttpCode(HttpStatus.OK)
  @Throttle({ default: { limit: 5, ttl: 60000 } }) // 5 attempts per minute
  @ApiOperation({ summary: 'Login with email/password' })
  @ApiResponse({ status: 200, description: 'Returns access and refresh tokens' })
  @ApiResponse({ status: 401, description: 'Invalid credentials or unverified email' })
  async login(@Body() dto: LoginDto): Promise<TokenPair> {
    return this.authService.login(dto);
  }

  @Public()
  @Post('refresh')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Refresh access token using refresh token' })
  @ApiResponse({ status: 200, description: 'Returns new token pair' })
  @ApiResponse({ status: 401, description: 'Invalid or expired refresh token' })
  async refresh(@Body() dto: RefreshTokenDto): Promise<TokenPair> {
    return this.authService.refreshTokens(dto);
  }

  @Post('logout')
  @HttpCode(HttpStatus.OK)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Logout and invalidate refresh token' })
  @ApiResponse({ status: 200, description: 'Logged out successfully' })
  async logout(@CurrentUser('_id') userId: string) {
    return this.authService.logout(userId);
  }

  // ─── Email Verification ──────────────────────────────

  @Public()
  @Get('verify-email')
  @ApiOperation({ summary: 'Verify email address with token' })
  @ApiResponse({ status: 200, description: 'Email verified successfully' })
  @ApiResponse({ status: 400, description: 'Invalid or expired token' })
  async verifyEmail(@Query('token') token: string) {
    return this.authService.verifyEmail(token);
  }

  // ─── Password Reset ─────────────────────────────────

  @Public()
  @Post('forgot-password')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Request a password reset email' })
  @ApiResponse({ status: 200, description: 'Reset email sent if account exists' })
  async forgotPassword(@Body() dto: ForgotPasswordDto) {
    return this.authService.forgotPassword(dto.email);
  }

  @Public()
  @Post('reset-password')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Reset password with token' })
  @ApiResponse({ status: 200, description: 'Password reset successfully' })
  @ApiResponse({ status: 400, description: 'Invalid or expired token' })
  async resetPassword(@Body() dto: ResetPasswordDto) {
    return this.authService.resetPassword(dto.token, dto.newPassword);
  }

  // ─── Google OAuth ────────────────────────────────────

  @Public()
  @Get('google')
  @UseGuards(GoogleAuthGuard)
  @ApiOperation({ summary: 'Initiate Google OAuth login' })
  async googleLogin() {
    // Guard redirects to Google
  }

  @Public()
  @Get('google/callback')
  @UseGuards(GoogleAuthGuard)
  @ApiOperation({ summary: 'Google OAuth callback' })
  async googleCallback(@Req() req: any): Promise<TokenPair> {
    return req.user;
  }

  @Post('google/mobile')
  @HttpCode(HttpStatus.OK)
  @ApiBearerAuth()
  @Public()
  @ApiOperation({ summary: 'Google OAuth for mobile (send access token from client SDK)' })
  @ApiResponse({ status: 200, description: 'Returns token pair' })
  async googleMobile(@Body() dto: SocialAuthDto): Promise<TokenPair> {
    // For mobile: the client sends the Google access token obtained via expo-auth-session
    // We validate it server-side by calling Google's userinfo endpoint
    const response = await fetch(`https://www.googleapis.com/oauth2/v3/userinfo`, {
      headers: { Authorization: `Bearer ${dto.accessToken}` },
    });
    const profile = await response.json() as any;
    return this.authService.validateGoogleUser({
      googleId: profile.sub,
      email: profile.email,
      displayName: profile.name || '',
      avatar: profile.picture,
    });
  }

  // ─── Facebook OAuth ──────────────────────────────────

  @Public()
  @Get('facebook')
  @UseGuards(FacebookAuthGuard)
  @ApiOperation({ summary: 'Initiate Facebook OAuth login' })
  async facebookLogin() {
    // Guard redirects to Facebook
  }

  @Public()
  @Get('facebook/callback')
  @UseGuards(FacebookAuthGuard)
  @ApiOperation({ summary: 'Facebook OAuth callback' })
  async facebookCallback(@Req() req: any): Promise<TokenPair> {
    return req.user;
  }

  @Post('facebook/mobile')
  @HttpCode(HttpStatus.OK)
  @Public()
  @ApiOperation({ summary: 'Facebook OAuth for mobile (send access token from client SDK)' })
  @ApiResponse({ status: 200, description: 'Returns token pair' })
  async facebookMobile(@Body() dto: SocialAuthDto): Promise<TokenPair> {
    const response = await fetch(`https://graph.facebook.com/me?fields=id,email,name,picture&access_token=${dto.accessToken}`);
    const profile = await response.json() as any;
    return this.authService.validateFacebookUser({
      facebookId: profile.id,
      email: profile.email,
      displayName: profile.name || '',
      avatar: profile.picture?.data?.url,
    });
  }

  // ─── Link Social Accounts ───────────────────────────

  @Post('link/google')
  @HttpCode(HttpStatus.OK)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Link Google account to current user' })
  @ApiResponse({ status: 200, description: 'Google account linked' })
  @ApiResponse({ status: 409, description: 'Google account already linked to another user' })
  async linkGoogle(
    @CurrentUser('_id') userId: string,
    @Body() dto: SocialAuthDto,
  ) {
    const response = await fetch(`https://www.googleapis.com/oauth2/v3/userinfo`, {
      headers: { Authorization: `Bearer ${dto.accessToken}` },
    });
    const profile = await response.json() as any;
    return this.authService.linkGoogle(userId, profile.sub);
  }

  @Post('link/facebook')
  @HttpCode(HttpStatus.OK)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Link Facebook account to current user' })
  @ApiResponse({ status: 200, description: 'Facebook account linked' })
  @ApiResponse({ status: 409, description: 'Facebook account already linked to another user' })
  async linkFacebook(
    @CurrentUser('_id') userId: string,
    @Body() dto: SocialAuthDto,
  ) {
    const response = await fetch(`https://graph.facebook.com/me?fields=id&access_token=${dto.accessToken}`);
    const profile = await response.json() as any;
    return this.authService.linkFacebook(userId, profile.id);
  }
}
