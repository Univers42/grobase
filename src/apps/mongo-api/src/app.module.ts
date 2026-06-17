/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   app.module.ts                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:11 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { MiddlewareConsumer, Module, NestModule, RequestMethod } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { LoggerModule } from 'nestjs-pino';
import { TerminusModule } from '@nestjs/terminus';
import { makeHistogramProvider } from '@willsoto/nestjs-prometheus';
import { MongoModule } from '@mini-baas/database';
import { CollectionsModule } from './collections/collections.module';
import { AdminModule } from './admin/admin.module';
import { HealthController } from './health.controller';
import { AuditModule, IdempotencyMiddleware, ObservabilityModule, createPinoHttpOptions } from '@mini-baas/common';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    LoggerModule.forRoot({ pinoHttp: createPinoHttpOptions('mongo-api') }),
    ObservabilityModule,
    TerminusModule,
    MongoModule,
    CollectionsModule,
    AdminModule,
    AuditModule,
  ],
  controllers: [HealthController],
  providers: [
    IdempotencyMiddleware,
    makeHistogramProvider({
      name: 'http_request_duration_seconds',
      help: 'Duration of HTTP requests in seconds',
      labelNames: ['method', 'route', 'status_code'],
      buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
    }),
  ],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    consumer.apply(IdempotencyMiddleware).forRoutes({ path: '*', method: RequestMethod.ALL });
  }
}
