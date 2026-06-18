/**
 * Dish Module
 */
import { Module } from '@nestjs/common';
import { DishController } from './dish.controller';
import { DishService } from './dish.service';

@Module({
  controllers: [DishController],
  providers: [DishService],
  exports: [DishService],
})
export class DishModule {}
