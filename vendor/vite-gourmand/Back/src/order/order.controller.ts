/**
 * Order Controller
 * Order management endpoints
 */
import { Controller, Get, Post, Put, Body, Param, Query } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { OrderService } from './order.service';
import { OrderStatusService } from './order-status.service';
import { CurrentUser, Roles, JwtPayload, SafeParseIntPipe } from '../common';
import {
  CreateOrderDto,
  UpdateOrderDto,
  OrderFilterDto,
} from './dto/order.dto';
import { UpdateStatusDto } from './dto/status.dto';

@ApiTags('orders')
@Controller('orders')
@ApiBearerAuth()
export class OrderController {
  constructor(
    private readonly orderService: OrderService,
    private readonly statusService: OrderStatusService,
  ) {}

  @Get()
  @ApiOperation({ summary: 'List orders (user sees own, admin sees all)' })
  async findAll(
    @CurrentUser() user: JwtPayload,
    @Query() filters: OrderFilterDto,
  ) {
    if (['admin', 'manager'].includes(user.role)) {
      return this.orderService.findAll(filters);
    }
    return this.orderService.findByUser(user.sub, filters);
  }

  @Get('my')
  @ApiOperation({ summary: 'Get current user orders' })
  async findMine(
    @CurrentUser() user: JwtPayload,
    @Query() filters: OrderFilterDto,
  ) {
    return this.orderService.findByUser(user.sub, filters);
  }

  @Get(':id')
  @ApiOperation({ summary: 'Get order by ID' })
  async findOne(
    @CurrentUser() user: JwtPayload,
    @Param('id', SafeParseIntPipe) id: number,
  ) {
    return this.orderService.findById(id, user);
  }

  @Post()
  @ApiOperation({ summary: 'Create new order' })
  async create(@CurrentUser() user: JwtPayload, @Body() dto: CreateOrderDto) {
    return this.orderService.create(user.sub, dto);
  }

  @Put(':id')
  @ApiOperation({ summary: 'Update order (before confirmation only)' })
  async update(
    @CurrentUser() user: JwtPayload,
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateOrderDto,
  ) {
    return this.orderService.update(id, dto, user);
  }

  @Post(':id/status')
  @Roles('admin', 'manager', 'employee')
  @ApiOperation({ summary: 'Update order status' })
  async updateStatus(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateStatusDto,
  ) {
    return this.statusService.updateStatus(id, dto.status, dto.notes);
  }

  @Get(':id/history')
  @ApiOperation({ summary: 'Get order status history' })
  async getHistory(@Param('id', SafeParseIntPipe) id: number) {
    return this.statusService.getHistory(id);
  }

  @Post(':id/cancel')
  @ApiOperation({ summary: 'Cancel order' })
  async cancel(
    @CurrentUser() user: JwtPayload,
    @Param('id', SafeParseIntPipe) id: number,
    @Body() body: { reason: string },
  ) {
    return this.orderService.cancel(id, user, body.reason);
  }
}
