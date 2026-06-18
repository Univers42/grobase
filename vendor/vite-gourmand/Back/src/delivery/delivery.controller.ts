/**
 * Delivery Controller
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
import { DeliveryService } from './delivery.service';
import { Roles, SafeParseIntPipe, CurrentUser } from '../common';
import {
  CreateDeliveryAssignmentDto,
  UpdateDeliveryAssignmentDto,
  RateDeliveryDto,
} from './dto/delivery.dto';
import { JwtPayload } from '../common/types/request.types';

@ApiTags('deliveries')
@Controller('deliveries')
@ApiBearerAuth()
export class DeliveryController {
  constructor(private readonly deliveryService: DeliveryService) {}

  @Get()
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'List all delivery assignments' })
  async findAll(
    @Query('status') status?: string,
    @Query('deliveryPersonId') deliveryPersonId?: string,
  ) {
    return this.deliveryService.findAll({
      status,
      deliveryPersonId: deliveryPersonId
        ? Number.parseInt(deliveryPersonId, 10)
        : undefined,
    });
  }

  @Get('pending')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get pending deliveries' })
  async getPending() {
    return this.deliveryService.getPendingDeliveries();
  }

  @Get('my')
  @Roles('employee')
  @ApiOperation({ summary: 'Get my assigned deliveries' })
  async getMyDeliveries(@CurrentUser() user: JwtPayload) {
    return this.deliveryService.getMyDeliveries(user.sub);
  }

  @Get(':id')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Get delivery assignment by ID' })
  async findOne(@Param('id', SafeParseIntPipe) id: number) {
    return this.deliveryService.findById(id);
  }

  @Get('order/:orderId')
  @Roles('admin', 'employee', 'client')
  @ApiOperation({ summary: 'Get delivery assignment by order ID' })
  async findByOrder(@Param('orderId', SafeParseIntPipe) orderId: number) {
    return this.deliveryService.findByOrderId(orderId);
  }

  @Post()
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Create delivery assignment' })
  async create(@Body() dto: CreateDeliveryAssignmentDto) {
    return this.deliveryService.create(dto);
  }

  @Put(':id')
  @Roles('admin', 'employee')
  @ApiOperation({ summary: 'Update delivery assignment' })
  async update(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: UpdateDeliveryAssignmentDto,
  ) {
    return this.deliveryService.update(id, dto);
  }

  @Delete(':id')
  @Roles('admin')
  @ApiOperation({ summary: 'Delete delivery assignment' })
  async delete(@Param('id', SafeParseIntPipe) id: number) {
    return this.deliveryService.delete(id);
  }

  @Post(':id/pickup')
  @Roles('employee')
  @ApiOperation({ summary: 'Mark delivery as picked up' })
  async markPickedUp(@Param('id', SafeParseIntPipe) id: number) {
    return this.deliveryService.markPickedUp(id);
  }

  @Post(':id/delivered')
  @Roles('employee')
  @ApiOperation({ summary: 'Mark delivery as delivered' })
  async markDelivered(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() body: { proofPhotoUrl?: string },
  ) {
    return this.deliveryService.markDelivered(id, body.proofPhotoUrl);
  }

  @Post(':id/rate')
  @Roles('client')
  @ApiOperation({ summary: 'Rate delivery (client only)' })
  async rateDelivery(
    @Param('id', SafeParseIntPipe) id: number,
    @Body() dto: RateDeliveryDto,
  ) {
    return this.deliveryService.rateDelivery(id, dto);
  }
}
