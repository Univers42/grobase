/**
 * Timing Attack Prevention E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Timing Attack Prevention (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  describe('Login Timing', () => {
    it('similar response time for valid/invalid email', async () => {
      // This is a heuristic test - timing should be roughly similar
      const iterations = 3;
      const validTimes: number[] = [];
      const invalidTimes: number[] = [];

      for (let i = 0; i < iterations; i++) {
        const start1 = Date.now();
        await request(app.getHttpServer())
          .post('/api/auth/login')
          .send({ email: 'admin@vitegourmand.fr', password: 'wrong' });
        validTimes.push(Date.now() - start1);

        const start2 = Date.now();
        await request(app.getHttpServer())
          .post('/api/auth/login')
          .send({ email: 'nonexistent@test.com', password: 'wrong' });
        invalidTimes.push(Date.now() - start2);
      }

      const avgValid = validTimes.reduce((a, b) => a + b) / iterations;
      const avgInvalid = invalidTimes.reduce((a, b) => a + b) / iterations;

      // Times should be within 500ms of each other (allowing for bcrypt)
      expect(Math.abs(avgValid - avgInvalid)).toBeLessThan(500);
    });
  });

  describe('Password Reset Timing', () => {
    it('similar response for existing/non-existing email', async () => {
      const start1 = Date.now();
      await request(app.getHttpServer())
        .post('/api/auth/forgot-password')
        .send({ email: 'admin@vitegourmand.fr' });
      const time1 = Date.now() - start1;

      const start2 = Date.now();
      await request(app.getHttpServer())
        .post('/api/auth/forgot-password')
        .send({ email: 'nonexistent@nowhere.com' });
      const time2 = Date.now() - start2;

      // Response times should be similar
      expect(Math.abs(time1 - time2)).toBeLessThan(1000);
    });
  });
});
