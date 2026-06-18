/**
 * Support Controller
 */
import { Controller, Get, Post, Put, Body, Param, Query } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { SupportService } from './support.service';
import { Roles, SafeParseIntPipe, CurrentUser } from '../common';
import {
  CreateSupportTicketDto,
  UpdateSupportTicketDto,
  CreateTicketMessageDto,
} from './dto/support.dto';
import { JwtPayload } from '../common/types/request.types';

@ApiTags('support')
@Controller('support')
@ApiBearerAuth()
export class SupportController {
  constructor(private readonly supportService: SupportService) {}

  // Customer endpoints
  @Get('my-tickets')
  @ApiOperation({ summary: 'Get my support tickets' })
  async getMyTickets(
    @CurrentUser() user: JwtPayload,
    @Query('limit') limit?: string,
    @Query('offset') offset?: string,
  ) {
    return this.supportService.getMyTickets(user.sub, {
      limit: limit ? Number.parseInt(limit, 10) : undefined,
      offset: offset ? Number.parseInt(offset, 10) : undefined,
    });
  }

  @Post()
  @ApiOperation({ summary: 'Create a support ticket' })
  async create(
    @Body() dto: CreateSupportTicketDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.supportService.create(user.sub, dto);
  }

  @Get('ticket/:ticketNumber')
  @ApiOperation({ summary: 'Get ticket by ticket number' })
  async findByTicketNumber(@Param('ticketNumber') ticketNumber: string) {
    return this.supportService.findByTicketNumber(ticketNumber);
  }

  @Post(':id/messages')
  @ApiOperation({ summary: 'Add message to ticket' })
  async addMessage(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: CreateTicketMessageDto,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.supportService.addMessage(id, user.sub, dto);
  }

  // Employee/Admin endpoints
  @Get()
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'List all support tickets (admin/employee)' })
  async findAll(
    @Query('status') status?: string,
    @Query('assignedTo') assignedTo?: string,
    @Query('limit') limit?: string,
    @Query('offset') offset?: string,
  ) {
    return this.supportService.findAll({
      status,
      assignedTo: assignedTo ? Number.parseInt(assignedTo, 10) : undefined,
      limit: limit ? Number.parseInt(limit, 10) : undefined,
      offset: offset ? Number.parseInt(offset, 10) : undefined,
    });
  }

  @Get('open')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get open tickets' })
  async getOpenTickets() {
    return this.supportService.getOpenTickets();
  }

  @Get('assigned-to-me')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get tickets assigned to me' })
  async getAssignedTickets(
    @CurrentUser() user: JwtPayload,
    @Query('limit') limit?: string,
    @Query('offset') offset?: string,
  ) {
    return this.supportService.getAssignedTickets(user.sub, {
      limit: limit ? Number.parseInt(limit, 10) : undefined,
      offset: offset ? Number.parseInt(offset, 10) : undefined,
    });
  }

  @Get('stats')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get support ticket statistics' })
  async getStats() {
    return this.supportService.getStats();
  }

  @Get(':id')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get ticket by ID (admin/employee)' })
  async findOne(@Param('id', SafeParseIntPipe) id: number) {
    return this.supportService.findById(id);
  }

  @Put(':id')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Update ticket' })
  async update(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateSupportTicketDto,
  ) {
    return this.supportService.update(id, dto);
  }

  @Post(':id/assign')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Assign ticket to employee' })
  async assignTicket(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() body: { assigneeId: number },
  ) {
    return this.supportService.assignTicket(id, body.assigneeId);
  }

  @Post(':id/take')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Take ownership of ticket' })
  async takeTicket(
    @Param('id', SafeParseIntPipe) id: number,
    @CurrentUser() user: JwtPayload,
  ) {
    return this.supportService.assignTicket(id, user.sub);
  }

  @Post(':id/resolve')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Mark ticket as resolved' })
  async resolveTicket(@Param('id', SafeParseIntPipe) id: number) {
    return this.supportService.resolveTicket(id);
  }

  @Post(':id/close')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Close ticket' })
  async closeTicket(@Param('id', SafeParseIntPipe) id: number) {
    return this.supportService.closeTicket(id);
  }
}
