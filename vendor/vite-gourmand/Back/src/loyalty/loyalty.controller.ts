/**
 * Loyalty Controller
 */
import { Controller, Get, Post, Body, Param, Query } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { LoyaltyService } from './loyalty.service';
import { Roles, SafeParseIntPipe, CurrentUser } from '../common';
import { RedeemPointsDto } from './dto/loyalty.dto';
import { JwtPayload } from '../common/types/request.types';

@ApiTags('loyalty')
@Controller('loyalty')
@ApiBearerAuth()
export class LoyaltyController {
  constructor(private readonly loyaltyService: LoyaltyService) {}

  @Get('me')
  @ApiOperation({
    summary: 'Get current user loyalty account and recent transactions',
  })
  async getMyAccount(@CurrentUser() user: JwtPayload) {
    return this.loyaltyService.getAccountWithTransactions(user.sub);
  }

  @Get('me/transactions')
  @ApiOperation({ summary: 'Get current user transaction history' })
  async getMyTransactions(
    @CurrentUser() user: JwtPayload,
    @Query('limit') limit?: string,
    @Query('offset') offset?: string,
  ) {
    return this.loyaltyService.getTransactionHistory(user.sub, {
      limit: limit ? Number.parseInt(limit, 10) : undefined,
      offset: offset ? Number.parseInt(offset, 10) : undefined,
    });
  }

  @Post('me/redeem')
  @ApiOperation({ summary: 'Redeem loyalty points' })
  async redeemPoints(
    @CurrentUser() user: JwtPayload,
    @Body() dto: RedeemPointsDto,
  ) {
    return this.loyaltyService.redeemPoints(user.sub, dto);
  }

  @Get('value/:points')
  @ApiOperation({ summary: 'Get euro value of points' })
  getPointsValue(@Param('points', SafeParseIntPipe) points: number) {
    return this.loyaltyService.getPointsValue(points);
  }

  // Admin endpoints
  @Get('accounts')
  @Roles('admin')
  @ApiOperation({ summary: 'List all loyalty accounts (admin only)' })
  async getAllAccounts(
    @Query('limit') limit?: string,
    @Query('offset') offset?: string,
  ) {
    return this.loyaltyService.getAllAccounts({
      limit: limit ? Number.parseInt(limit, 10) : undefined,
      offset: offset ? Number.parseInt(offset, 10) : undefined,
    });
  }

  @Get('accounts/:userId')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get user loyalty account by user ID' })
  async getAccountByUserId(@Param('userId', SafeParseIntPipe) userId: number) {
    return this.loyaltyService.getAccountWithTransactions(userId);
  }

  @Post('accounts/:userId/bonus')
  @Roles('admin')
  @ApiOperation({ summary: 'Add bonus points to user account' })
  async addBonusPoints(
    @Param('userId', SafeParseIntPipe) userId: number,
    @Body() body: { points: number; description: string },
  ) {
    return this.loyaltyService.addBonusPoints(
      userId,
      body.points,
      body.description,
    );
  }
}
