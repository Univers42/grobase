import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, HttpStatus } from '@nestjs/common';
import * as request from 'supertest';

describe('Subscription E2E', () => {
  let app: INestApplication;
  let authToken: string;

  beforeAll(async () => {
    // In a real setup, we'd create the app and authenticate
    // This is a skeleton for the E2E test
  });

  afterAll(async () => {
    if (app) await app.close();
  });

  describe('GET /subscription/plans', () => {
    it('should return available plans', async () => {
      // Arrange & Act
      const response = await request(app?.getHttpServer?.() || 'http://localhost:3000')
        .get('/subscription/plans')
        .expect(HttpStatus.OK);

      // Assert
      expect(response.body).toBeDefined();
      expect(Array.isArray(response.body.data || response.body)).toBe(true);
    });
  });

  describe('GET /subscription/current', () => {
    it('should return 401 without auth', async () => {
      await request(app?.getHttpServer?.() || 'http://localhost:3000')
        .get('/subscription/current')
        .expect(HttpStatus.UNAUTHORIZED);
    });

    it('should return current subscription with auth', async () => {
      if (!authToken) return;
      const response = await request(app?.getHttpServer?.() || 'http://localhost:3000')
        .get('/subscription/current')
        .set('Authorization', `Bearer ${authToken}`)
        .expect(HttpStatus.OK);

      expect(response.body).toHaveProperty('plan');
    });
  });

  describe('POST /subscription/subscribe', () => {
    it('should return 401 without auth', async () => {
      await request(app?.getHttpServer?.() || 'http://localhost:3000')
        .post('/subscription/subscribe')
        .send({ plan: 'premium' })
        .expect(HttpStatus.UNAUTHORIZED);
    });
  });

  describe('POST /subscription/cancel', () => {
    it('should return 401 without auth', async () => {
      await request(app?.getHttpServer?.() || 'http://localhost:3000')
        .post('/subscription/cancel')
        .expect(HttpStatus.UNAUTHORIZED);
    });
  });
});
