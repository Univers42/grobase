/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   main.ts                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/02 12:43:56 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { NestFactory } from '@nestjs/core';
import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { Logger as PinoLogger } from 'nestjs-pino';
import { AppModule } from './app.module';
import {
  AllExceptionsFilter,
  CorrelationIdInterceptor,
  TransformInterceptor,
  applySecurityMiddleware,
  createValidationPipe,
  startOtel,
} from '@mini-baas/common';

startOtel('session-service');

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });

  app.useLogger(app.get(PinoLogger));
  applySecurityMiddleware(app);
  app.useGlobalPipes(createValidationPipe());
  app.useGlobalFilters(new AllExceptionsFilter());
  app.useGlobalInterceptors(
    new CorrelationIdInterceptor(),
    new TransformInterceptor(),
  );
  app.enableShutdownHooks();

  const swaggerConfig = new DocumentBuilder()
    .setTitle('Session Service')
    .setDescription('Token-based session lifecycle management with admin controls')
    .setVersion('1.0.0')
    .addApiKey({ type: 'apiKey', name: 'apikey', in: 'header' }, 'apikey')
    .addBearerAuth()
    .build();
  const doc = SwaggerModule.createDocument(app, swaggerConfig);
  SwaggerModule.setup('docs', app, doc);

  const config = app.get(ConfigService);
  const port = config.get<number>('PORT', 3120);

  await app.listen(port);
  Logger.log(`session-service listening on :${port}`, 'Bootstrap');
}

void bootstrap();
