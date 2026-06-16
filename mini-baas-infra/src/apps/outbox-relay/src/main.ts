/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   main.ts                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 15:40:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 20:48:08 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { Logger as PinoLogger } from 'nestjs-pino';
import { AllExceptionsFilter, CorrelationIdInterceptor, applySecurityMiddleware, createValidationPipe, startOtel } from '@mini-baas/common';
import { AppModule } from './app.module';

startOtel('outbox-relay');

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });

  app.useLogger(app.get(PinoLogger));
  applySecurityMiddleware(app);
  app.useGlobalPipes(createValidationPipe());
  app.useGlobalFilters(new AllExceptionsFilter());
  app.useGlobalInterceptors(new CorrelationIdInterceptor());
  app.enableShutdownHooks();

  const swaggerConfig = new DocumentBuilder()
    .setTitle('Outbox Relay')
    .setDescription('Publishes PostgreSQL outbox events to Redis Streams and Mongo projections')
    .setVersion('3.0.0')
    .build();
  const doc = SwaggerModule.createDocument(app, swaggerConfig);
  SwaggerModule.setup('docs', app, doc);

  const config = app.get(ConfigService);
  const port = config.get<number>('PORT', 3130);

  await app.listen(port);
  Logger.log(`outbox-relay listening on :${port}`, 'Bootstrap');
}

void bootstrap();