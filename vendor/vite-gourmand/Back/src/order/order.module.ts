/**
 * Order Module
 * Provides order management functionality
 */
import { Module } from '@nestjs/common';
import { OrderController } from './order.controller';
import { OrderService } from './order.service';
import { OrderStatusService } from './order-status.service';

@Module({
  controllers: [OrderController],
  providers: [OrderService, OrderStatusService],
  exports: [OrderService],
})
export class OrderModule {}
