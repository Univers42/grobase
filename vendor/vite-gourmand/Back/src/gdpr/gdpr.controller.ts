/**
 * GDPR Controller
 */
import {
  Controller,
  Get,
  Post,
  Put,
  Delete,
  Body,
  Param,
  Query,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { GdprService } from './gdpr.service';
import { Roles, SafeParseIntPipe, CurrentUser } from '../common';
import {
  CreateUserConsentDto,
  UpdateUserConsentDto,
  CreateDataDeletionRequestDto,
  ProcessDataDeletionRequestDto,
} from './dto/gdpr.dto';
import { JwtPayload } from '../common/types/request.types';

@ApiTags('gdpr')
@Controller('gdpr')
@ApiBearerAuth()
export class GdprController {
  constructor(private readonly gdprService: GdprService) {}

  // ============ User Consent Endpoints ============

  @Get('consent')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Get my consents' })
  async getMyConsents(@CurrentUser() user: JwtPayload) {
    return this.gdprService.getUserConsents(user.sub);
  }

  @Get('consent/:type')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Get specific consent' })
  async getConsent(
    @Param('type') type: string,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.gdprService.getUserConsent(user.sub, type);
  }

  @Post('consent')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Set consent' })
  async setConsent(
    @Body() dto: CreateUserConsentDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.gdprService.setUserConsent(user.sub, dto);
  }

  @Put('consent/:type')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Update consent' })
  async updateConsent(
    @Param('type') type: string,
    @Body() dto: UpdateUserConsentDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.gdprService.updateConsent(user.sub, type, dto);
  }

  @Post('consent/withdraw-all')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Withdraw all non-essential consents' })
  async withdrawAllConsents(@CurrentUser() user: JwtPayload) {
    return this.gdprService.withdrawAllConsents(user.sub);
  }

  // ============ Data Export (Portability) ============

  @Get('export')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Export my personal data (GDPR data portability)' })
  async exportMyData(@CurrentUser() user: JwtPayload) {
    return this.gdprService.exportUserData(user.sub);
  }

  // ============ Data Deletion Requests ============

  @Post('deletion-request')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Request account deletion (right to be forgotten)' })
  async createDeletionRequest(
    @Body() dto: CreateDataDeletionRequestDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.gdprService.createDeletionRequest(user.sub, dto);
  }

  @Get('deletion-request/my')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Get my deletion request status' })
  async getMyDeletionRequest(@CurrentUser() user: JwtPayload) {
    return this.gdprService.getMyDeletionRequest(user.sub);
  }

  @Delete('deletion-request')
  @Roles('user', 'admin', 'employee')
  @ApiOperation({ summary: 'Cancel my deletion request' })
  async cancelDeletionRequest(@CurrentUser() user: JwtPayload) {
    return this.gdprService.cancelDeletionRequest(user.sub);
  }

  // ============ Admin Endpoints ============

  @Get('admin/deletion-requests')
  @Roles('admin')
  @ApiOperation({ summary: 'Get all deletion requests (admin)' })
  async getAllDeletionRequests(@Query('status') status?: string) {
    return this.gdprService.getAllDeletionRequests({ status });
  }

  @Get('admin/deletion-requests/pending')
  @Roles('admin')
  @ApiOperation({ summary: 'Get pending deletion requests (admin)' })
  async getPendingDeletionRequests() {
    return this.gdprService.getPendingDeletionRequests();
  }

  @Get('admin/deletion-requests/:id')
  @Roles('admin')
  @ApiOperation({ summary: 'Get deletion request by ID (admin)' })
  async getDeletionRequestById(@Param('id', SafeParseIntPipe) id: number) {
    return this.gdprService.getDeletionRequestById(id);
  }

  @Post('admin/deletion-requests/:id/process')
  @Roles('admin')
  @ApiOperation({ summary: 'Process deletion request (admin)' })
  async processDeletionRequest(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: ProcessDataDeletionRequestDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.gdprService.processDeletionRequest(id, dto, user.sub);
  }

  @Get('admin/users/:userId/data')
  @Roles('admin')
  @ApiOperation({ summary: 'Export user data (admin)' })
  async exportUserData(@Param('userId', SafeParseIntPipe) userId: number) {
    return this.gdprService.exportUserData(userId);
  }

  @Get('admin/users/:userId/consents')
  @Roles('admin')
  @ApiOperation({ summary: 'Get user consents (admin)' })
  async getUserConsents(@Param('userId', SafeParseIntPipe) userId: number) {
    return this.gdprService.getUserConsents(userId);
  }
}
