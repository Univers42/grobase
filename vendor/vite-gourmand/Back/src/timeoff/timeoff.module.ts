/**
 * Time Off Module
 */
import { Module } from '@nestjs/common';
import { TimeOffController } from './timeoff.controller';
import { TimeOffService } from './timeoff.service';
import { EmployeeTimeOffService } from './employee-timeoff.service';
import { AdminTimeOffService } from './admin-timeoff.service';
import { PrismaModule } from '../prisma';

@Module({
  imports: [PrismaModule],
  controllers: [TimeOffController],
  providers: [TimeOffService, EmployeeTimeOffService, AdminTimeOffService],
  exports: [TimeOffService, EmployeeTimeOffService, AdminTimeOffService],
})
export class TimeOffModule {}
