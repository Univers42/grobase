/**
 * Admin Module
 */
import { Module } from '@nestjs/common';
import { AdminController } from './admin.controller';
import { AdminService } from './admin.service';
import { StatsService } from './stats.service';

@Module({
  controllers: [AdminController],
  providers: [AdminService, StatsService],
  exports: [AdminService],
})
export class AdminModule {}
