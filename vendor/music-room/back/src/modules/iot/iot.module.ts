import { Module } from '@nestjs/common';
import { IoTService } from './iot.service';
import { IoTController } from './iot.controller';

@Module({
  controllers: [IoTController],
  providers: [IoTService],
  exports: [IoTService],
})
export class IoTModule {}
