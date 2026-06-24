import { Module } from '@nestjs/common';
import { APP_INTERCEPTOR } from '@nestjs/core';
import { MongooseModule } from '@nestjs/mongoose';
import { RequestLog, RequestLogSchema } from './schemas';
import { LoggingInterceptor } from './logging.interceptor';
import { LoggingService } from './logging.service';
import { LoggingController } from './logging.controller';

@Module({
  imports: [
    MongooseModule.forFeature([
      { name: RequestLog.name, schema: RequestLogSchema },
    ]),
  ],
  controllers: [LoggingController],
  providers: [
    LoggingService,
    // Register as global interceptor
    {
      provide: APP_INTERCEPTOR,
      useClass: LoggingInterceptor,
    },
  ],
  exports: [LoggingService],
})
export class LoggingModule {}
