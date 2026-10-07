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
import { StorageModule } from './storage/storage.module';
import { HealthController } from './health.controller';
import {
  AuditModule,
  IDENTITY_SECRETS,
  IdempotencyMiddleware,
  ObservabilityModule,
  createPinoHttpOptions,
  validateEnv,
} from '@mini-baas/common';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      validate: validateEnv({
        service: 'storage-router',
        secrets: [...IDENTITY_SECRETS, 'DATABASE_URL'],
      }),
    }),
    LoggerModule.forRoot({ pinoHttp: createPinoHttpOptions('storage-router') }),
    ObservabilityModule,
    TerminusModule,
    StorageModule,
    AuditModule,
  ],
  controllers: [HealthController],
  providers: [IdempotencyMiddleware],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer) {
    consumer.apply(IdempotencyMiddleware).forRoutes({ path: '*', method: RequestMethod.ALL });
  }
}
