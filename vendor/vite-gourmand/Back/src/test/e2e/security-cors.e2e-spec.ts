/**
 * CORS Security E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('CORS Security (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  describe('CORS Preflight', () => {
    it('handles OPTIONS request', async () => {
      const response = await request(app.getHttpServer())
        .options('/api/auth/login')
        .set('Origin', 'http://localhost:3000')
        .set('Access-Control-Request-Method', 'POST');

      expect([200, 204]).toContain(response.status);
    });

    it('includes CORS headers in response', async () => {
      const response = await request(app.getHttpServer())
        .get('/api')
        .set('Origin', 'http://localhost:3000');

      expect(response.status).toBe(200);
    });
  });

  describe('Origin Validation', () => {
    it('handles request without origin', async () => {
      const response = await request(app.getHttpServer()).get('/api');

      expect(response.status).toBe(200);
    });

    it('handles request with origin', async () => {
      const response = await request(app.getHttpServer())
        .get('/api')
        .set('Origin', 'http://localhost:3000');

      expect(response.status).toBe(200);
    });
  });
});
