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
import { LoggerModule } from 'nestjs-pino';
import { TerminusModule } from '@nestjs/terminus';
import { MongoModule } from '@mini-baas/database';
import { ChatModule } from './chat/chat.module';
import { PromptsModule } from './prompts/prompts.module';
import { HealthController } from './health.controller';

import { ObservabilityModule, createPinoHttpOptions } from '@mini-baas/common';
@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    LoggerModule.forRoot({ pinoHttp: createPinoHttpOptions('ai-service') }),
    ObservabilityModule,
    TerminusModule,
    MongoModule,
    ChatModule,
    PromptsModule,
  ],
  controllers: [HealthController],
})
export class AppModule {}
