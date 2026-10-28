/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   main.ts                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/02 12:43:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { NestFactory } from '@nestjs/core';
import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { Logger as PinoLogger } from 'nestjs-pino';
import { urlencoded } from 'express';
import { AppModule } from './app.module';
import { bigJsonLimit, jsonBodyParser, parseBigCollections } from './body-limits';
import {
  AllExceptionsFilter,
  CorrelationIdInterceptor,
  applySecurityMiddleware,
  createValidationPipe,
  startOtel,
} from '@mini-baas/common';

startOtel('mongo-api');

async function bootstrap() {
  // Nest's built-in parsers are off so the JSON limit can depend on the collection.
  const app = await NestFactory.create(AppModule, { bufferLogs: true, bodyParser: false });
  const config = app.get(ConfigService);

  app.useLogger(app.get(PinoLogger));
  applySecurityMiddleware(app);
  const big = parseBigCollections(config.get<string>('MONGO_API_BIG_COLLECTIONS'));
  if (big.rejected.length > 0) {
    Logger.warn(
      `MONGO_API_BIG_COLLECTIONS ignores invalid names: ${big.rejected.join(', ')}`,
      'Bootstrap',
    );
  }
  app.use(jsonBodyParser(big.names, bigJsonLimit(config.get<string>('MONGO_API_BIG_JSON_LIMIT'))));
  app.use(urlencoded({ extended: true }));
  app.useGlobalPipes(createValidationPipe());
  app.useGlobalFilters(new AllExceptionsFilter());
  app.useGlobalInterceptors(new CorrelationIdInterceptor());
  app.enableShutdownHooks();

  const swaggerConfig = new DocumentBuilder()
    .setTitle('Mongo API')
    .setDescription('MongoDB REST CRUD with per-user document isolation')
    .setVersion('2.0.0')
    .addBearerAuth()
    .build();
  const doc = SwaggerModule.createDocument(app, swaggerConfig);
  SwaggerModule.setup('docs', app, doc);

  const port = config.get<number>('PORT', 3010);

  await app.listen(port);
  Logger.log(`mongo-api listening on :${port}`, 'Bootstrap');
}

void bootstrap();
