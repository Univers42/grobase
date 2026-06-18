/**
 * Test Module Configuration
 * Provides test-friendly AppModule with disabled rate limiting
 */

import { Test, TestingModule, TestingModuleBuilder } from '@nestjs/testing';
import { INestApplication, ValidationPipe, CanActivate } from '@nestjs/common';
import { ThrottlerGuard } from '@nestjs/throttler';
import { AppModule } from '../app.module';

const mockThrottlerGuard: CanActivate = { canActivate: () => true };

/**
 * Creates test application with throttling disabled
 */
export async function createTestApp(): Promise<INestApplication> {
  const builder: TestingModuleBuilder = Test.createTestingModule({
    imports: [AppModule],
  });

  builder.overrideGuard(ThrottlerGuard).useValue(mockThrottlerGuard);

  const moduleFixture: TestingModule = await builder.compile();

  const app = moduleFixture.createNestApplication({ logger: ['error'] });
  app.setGlobalPrefix('api');
  app.enableCors();
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }));

  await app.init();
  return app;
}

/** Test utilities */
export const testUtils = {
  uniqueEmail: (prefix = 'test') => `${prefix}-${Date.now()}@test.com`,
  wait: (ms: number) => new Promise((resolve) => setTimeout(resolve, ms)),
  credentials: {
    admin: { email: 'admin@vitegourmand.fr', password: 'Admin123!' },
    manager: { email: 'manager@vitegourmand.fr', password: 'Manager123!' },
    client: { email: 'alice.dupont@email.fr', password: 'Client123!' },
    test: { email: 'test@test.com', password: 'Test123!' },
  },
};
