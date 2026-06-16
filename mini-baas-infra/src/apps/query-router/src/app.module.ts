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
import { HttpModule } from '@nestjs/axios';
import { LoggerModule } from 'nestjs-pino';
import { TerminusModule } from '@nestjs/terminus';
import { QueryModule } from './query/query.module';
import { HealthController } from './health.controller';
import { ApiKeyMiddleware, AuditModule, IdempotencyMiddleware, ObservabilityModule, createPinoHttpOptions } from '@mini-baas/common';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    LoggerModule.forRoot({ pinoHttp: createPinoHttpOptions('query-router') }),
    ObservabilityModule,
    TerminusModule,
    HttpModule,
    QueryModule,
    AuditModule,
  ],
  controllers: [HealthController],
  providers: [ApiKeyMiddleware, IdempotencyMiddleware],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    // ApiKey first: it materialises tenant headers from X-Baas-Api-Key so
    // the identity-resolution pipeline downstream sees a tenant envelope.
    consumer.apply(ApiKeyMiddleware).forRoutes({ path: '*', method: RequestMethod.ALL });
    consumer.apply(IdempotencyMiddleware).forRoutes({ path: '*', method: RequestMethod.ALL });
  }
}
