/**
 * Time Off Controller
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
import { TimeOffService } from './timeoff.service';
import { Roles, SafeParseIntPipe, CurrentUser } from '../common';
import {
  CreateTimeOffRequestDto,
  UpdateTimeOffRequestDto,
  DecideTimeOffRequestDto,
} from './dto/timeoff.dto';
import { JwtPayload } from '../common/types/request.types';

@ApiTags('time-off')
@Controller('time-off')
@ApiBearerAuth()
export class TimeOffController {
  constructor(private readonly timeoffService: TimeOffService) {}

  // Employee endpoints
  @Get('my-requests')
  @Roles('employee')
  @ApiOperation({ summary: 'Get my time off requests' })
  async getMyRequests(@CurrentUser() user: JwtPayload) {
    // Assuming employee_id is available - this might need adjustment based on actual user structure
    return this.timeoffService.getMyRequests(user.sub);
  }

  @Post()
  @Roles('employee')
  @ApiOperation({ summary: 'Create time off request' })
  async createRequest(
    @Body() dto: CreateTimeOffRequestDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.timeoffService.createRequest(dto, user.sub);
  }

  @Put(':id')
  @Roles('employee')
  @ApiOperation({ summary: 'Update my time off request' })
  async updateRequest(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateTimeOffRequestDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.timeoffService.updateRequest(id, dto, user.sub);
  }

  @Post(':id/cancel')
  @Roles('employee')
  @ApiOperation({ summary: 'Cancel my time off request' })
  async cancelRequest(
    @Param('id', SafeParseIntPipe) id: number,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.timeoffService.cancelRequest(id, user.sub);
  }

  // Admin endpoints
  @Get()
  @Roles('admin')
  @ApiOperation({ summary: 'Get all time off requests (admin)' })
  async findAll(
    @Query('status') status?: string,
    @Query('userId') userId?: string,
  ) {
    return this.timeoffService.findAll({
      status,
      userId: userId ? Number.parseInt(userId, 10) : undefined,
    });
  }

  @Get('pending')
  @Roles('admin')
  @ApiOperation({ summary: 'Get pending time off requests (admin)' })
  async getPendingRequests() {
    return this.timeoffService.getPendingRequests();
  }

  @Get('schedule')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get employee schedule (who is off)' })
  async getSchedule(
    @Query('startDate') startDate: string,
    @Query('endDate') endDate: string,
  ) {
    return this.timeoffService.getSchedule(
      new Date(startDate),
      new Date(endDate),
    );
  }

  @Get(':id')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get time off request by ID' })
  async findById(@Param('id', SafeParseIntPipe) id: number) {
    return this.timeoffService.findById(id);
  }

  @Post(':id/decide')
  @Roles('admin')
  @ApiOperation({ summary: 'Approve or reject time off request' })
  async decideRequest(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: DecideTimeOffRequestDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.timeoffService.decideRequest(id, dto, user.sub);
  }

  @Delete(':id')
  @Roles('admin')
  @ApiOperation({ summary: 'Delete time off request (admin)' })
  async deleteRequest(@Param('id', SafeParseIntPipe) id: number) {
    return this.timeoffService.deleteRequest(id);
  }
}
