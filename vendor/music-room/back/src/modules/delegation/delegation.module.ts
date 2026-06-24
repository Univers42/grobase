import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { Device, DeviceSchema } from './schemas/device.schema';
import { Delegation, DelegationSchema } from './schemas/delegation.schema';
import { DelegationService } from './delegation.service';
import { DelegationController } from './delegation.controller';

@Module({
  imports: [
    MongooseModule.forFeature([
      { name: Device.name, schema: DeviceSchema },
      { name: Delegation.name, schema: DelegationSchema },
    ]),
  ],
  controllers: [DelegationController],
  providers: [DelegationService],
  exports: [DelegationService],
})
export class DelegationModule {}
