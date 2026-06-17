/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   app.module.ts                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 21:16:42 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { LoggerModule } from 'nestjs-pino';
import { TerminusModule } from '@nestjs/terminus';
import { PostgresModule } from '@mini-baas/database';
import { PermissionsModule } from './permissions/permissions.module';
import { PoliciesModule } from './policies/policies.module';
import { DecisionsModule } from './decisions/decisions.module';
import { BundlesModule } from './bundles/bundles.module';
import { HealthController } from './health.controller';
import { AuditModule, ObservabilityModule, createPinoHttpOptions } from '@mini-baas/common';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    LoggerModule.forRoot({ pinoHttp: createPinoHttpOptions('permission-engine') }),
    ObservabilityModule,
    TerminusModule,
    PostgresModule,
    PermissionsModule,
    PoliciesModule,
    DecisionsModule,
    BundlesModule,
    AuditModule,
  ],
  controllers: [HealthController],
})
export class AppModule {}
