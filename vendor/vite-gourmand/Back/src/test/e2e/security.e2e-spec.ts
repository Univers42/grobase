/**
 * API Security E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('API Security (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('rejects invalid JWT token', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/users/me')
      .set('Authorization', 'Bearer invalid-token');

    expect(response.status).toBe(401);
  });

  it('rejects expired JWT token', async () => {
    const expiredToken =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.' +
      'eyJzdWIiOjEsImVtYWlsIjoidGVzdEB0ZXN0LmNvbSIsImlhdCI6MTUxNjIzOTAyMiwiZXhwIjoxNTE2MjM5MDIyfQ.' +
      'invalid-signature';

    const response = await request(app.getHttpServer())
      .get('/api/users/me')
      .set('Authorization', `Bearer ${expiredToken}`);

    expect(response.status).toBe(401);
  });

  it('rejects malformed auth header', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/users/me')
      .set('Authorization', 'NotBearer token');

    expect(response.status).toBe(401);
  });

  it('public endpoints work without auth', async () => {
    const publicEndpoints = [
      '/api',
      '/api/health',
      '/api/menus',
      '/api/dishes',
      '/api/themes',
      '/api/allergens',
      '/api/diets',
      '/api/working-hours',
    ];

    for (const endpoint of publicEndpoints) {
      const response = await request(app.getHttpServer()).get(endpoint);
      expect([200, 304]).toContain(response.status);
    }
  });

  it('protected endpoints require auth', async () => {
    const protectedEndpoints = [
      { method: 'get', path: '/api/users/me' },
      { method: 'get', path: '/api/orders' },
      { method: 'get', path: '/api/auth/me' },
    ];

    for (const { method, path } of protectedEndpoints) {
      const response = await (request(app.getHttpServer()) as any)[method](
        path,
      );
      expect(response.status).toBe(401);
    }
  });
});
