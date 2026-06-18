import {
  Controller,
  Post,
  Get,
  Patch,
  Delete,
  Param,
  Body,
} from '@nestjs/common';
import {
  ApiTags,
  ApiBearerAuth,
  ApiOperation,
  ApiParam,
} from '@nestjs/swagger';
import { DelegationService } from './delegation.service';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import {
  RegisterDeviceDto,
  UpdateDeviceDto,
  CreateDelegationDto,
  UpdateDelegationPermissionsDto,
} from './dto';

@ApiTags('delegations')
@ApiBearerAuth()
@Controller()
export class DelegationController {
  constructor(private readonly delegationService: DelegationService) {}

  // ─── Devices ───

  @Post('devices')
  @ApiOperation({ summary: 'Register a new device' })
  async registerDevice(
    @CurrentUser() user: any,
    @Body() dto: RegisterDeviceDto,
  ) {
    return this.delegationService.registerDevice(user._id, dto);
  }

  @Get('devices')
  @ApiOperation({ summary: 'List my active devices' })
  async getMyDevices(@CurrentUser() user: any) {
    return this.delegationService.getMyDevices(user._id);
  }

  @Patch('devices/:id')
  @ApiOperation({ summary: 'Update a device' })
  @ApiParam({ name: 'id', description: 'Device ID' })
  async updateDevice(
    @CurrentUser() user: any,
    @Param('id') id: string,
    @Body() dto: UpdateDeviceDto,
  ) {
    return this.delegationService.updateDevice(id, user._id, dto);
  }

  @Delete('devices/:id')
  @ApiOperation({ summary: 'Deactivate a device' })
  @ApiParam({ name: 'id', description: 'Device ID' })
  async removeDevice(
    @CurrentUser() user: any,
    @Param('id') id: string,
  ) {
    return this.delegationService.removeDevice(id, user._id);
  }

  @Post('devices/:id/heartbeat')
  @ApiOperation({ summary: 'Send device heartbeat' })
  @ApiParam({ name: 'id', description: 'Device ID' })
  async heartbeat(
    @CurrentUser() user: any,
    @Param('id') id: string,
  ) {
    await this.delegationService.heartbeat(id, user._id);
    return { status: 'ok' };
  }

  // ─── Delegations ───

  @Post('delegations')
  @ApiOperation({ summary: 'Create a new delegation' })
  async createDelegation(
    @CurrentUser() user: any,
    @Body() dto: CreateDelegationDto,
  ) {
    return this.delegationService.createDelegation(user._id, dto);
  }

  @Post('delegations/:id/accept')
  @ApiOperation({ summary: 'Accept a pending delegation' })
  @ApiParam({ name: 'id', description: 'Delegation ID' })
  async acceptDelegation(
    @CurrentUser() user: any,
    @Param('id') id: string,
  ) {
    return this.delegationService.acceptDelegation(id, user._id);
  }

  @Post('delegations/:id/revoke')
  @ApiOperation({ summary: 'Revoke an active delegation' })
  @ApiParam({ name: 'id', description: 'Delegation ID' })
  async revokeDelegation(
    @CurrentUser() user: any,
    @Param('id') id: string,
  ) {
    return this.delegationService.revokeDelegation(id, user._id);
  }

  @Patch('delegations/:id/permissions')
  @ApiOperation({ summary: 'Update delegation permissions' })
  @ApiParam({ name: 'id', description: 'Delegation ID' })
  async updatePermissions(
    @CurrentUser() user: any,
    @Param('id') id: string,
    @Body() dto: UpdateDelegationPermissionsDto,
  ) {
    return this.delegationService.updatePermissions(id, user._id, dto);
  }

  @Get('delegations/granted')
  @ApiOperation({ summary: 'Get delegations I granted' })
  async getGrantedDelegations(@CurrentUser() user: any) {
    return this.delegationService.getGrantedDelegations(user._id);
  }

  @Get('delegations/received')
  @ApiOperation({ summary: 'Get delegations I received' })
  async getReceivedDelegations(@CurrentUser() user: any) {
    return this.delegationService.getReceivedDelegations(user._id);
  }
}
