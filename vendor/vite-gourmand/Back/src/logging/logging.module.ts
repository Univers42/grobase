/**
 * Logging Module
 */
import { Module, Global } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { HttpLogInterceptor } from './http-log.interceptor';
import { LogService } from './log.service';
import { LogController } from './log.controller';

@Global()
@Module({
  imports: [
    ConfigModule,
    JwtModule.registerAsync({
      imports: [ConfigModule],
      useFactory: (configService: ConfigService) => ({
        secret: configService.get<string>('JWT_SECRET') || 'secret',
      }),
      inject: [ConfigService],
    }),
  ],
  controllers: [LogController],
  providers: [HttpLogInterceptor, LogService],
  exports: [HttpLogInterceptor, LogService],
})
export class LoggingModule {}
