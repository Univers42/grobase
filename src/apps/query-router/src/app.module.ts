import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { HttpModule } from '@nestjs/axios';
import { LoggerModule } from 'nestjs-pino';
import { TerminusModule } from '@nestjs/terminus';
import { PrometheusModule } from '@willsoto/nestjs-prometheus';
import { QueryModule } from './query/query.module';
import { HealthController } from './health.controller';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    LoggerModule.forRoot({
      pinoHttp: {
        level: process.env['LOG_LEVEL'] ?? 'info',
        genReqId: (req: { headers?: Record<string, unknown> }) =>
          (req.headers?.['x-request-id'] as string) ??
          `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
        transport:
          process.env['NODE_ENV'] !== 'production'
            ? { target: 'pino-pretty', options: { colorize: true } }
            : undefined,
        base: { service: 'query-router' },
      },
    }),
    TerminusModule,
    PrometheusModule.register({ defaultMetrics: { enabled: true } }),
    HttpModule,
    QueryModule,
  ],
  controllers: [HealthController],
})
export class AppModule {}
