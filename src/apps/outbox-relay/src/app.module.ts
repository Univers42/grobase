/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   app.module.ts                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 15:40:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 21:16:42 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { TerminusModule } from '@nestjs/terminus';
import { LoggerModule } from 'nestjs-pino';
import { MongoModule, PostgresModule } from '@mini-baas/database';
import { HealthController } from './health.controller';
import { OutboxRelayService } from './outbox-relay.service';
import { SagaCoordinatorService } from './saga-coordinator.service';

import { ObservabilityModule, createPinoHttpOptions } from '@mini-baas/common';
@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    LoggerModule.forRoot({ pinoHttp: createPinoHttpOptions('outbox-relay') }),
    ObservabilityModule,
    TerminusModule,
    PostgresModule,
    MongoModule,
  ],
  controllers: [HealthController],
  providers: [OutboxRelayService, SagaCoordinatorService],
})
export class AppModule {}