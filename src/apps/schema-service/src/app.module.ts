/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   app.module.ts                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:12 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { HttpModule } from '@nestjs/axios';
import { LoggerModule } from 'nestjs-pino';
import { TerminusModule } from '@nestjs/terminus';
import { PostgresModule } from '@mini-baas/database';
import { ObservabilityModule, createPinoHttpOptions } from '@mini-baas/common';
import { SchemasModule } from './schemas/schemas.module';
import { HealthController } from './health.controller';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    LoggerModule.forRoot({ pinoHttp: createPinoHttpOptions('schema-service') }),
    ObservabilityModule,
    TerminusModule,
    HttpModule,
    PostgresModule,
    SchemasModule,
  ],
  controllers: [HealthController],
})
export class AppModule {}
