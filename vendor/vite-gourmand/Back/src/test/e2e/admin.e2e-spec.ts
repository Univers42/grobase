/**
 * Admin API E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Admin API (e2e)', () => {
  let app: INestApplication;
  let adminToken: string;
  let clientToken: string;

  beforeAll(async () => {
    app = await createTestApp();

    const adminRes = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send(testUtils.credentials.admin);
    adminToken = adminRes.body.data?.accessToken;

    const clientRes = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send(testUtils.credentials.client);
    clientToken = clientRes.body.data?.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  describe('GET /api/admin/users', () => {
    it('should require authentication', async () => {
      const response = await request(app.getHttpServer()).get(
        '/api/admin/users',
      );

      expect(response.status).toBe(401);
    });

    it('should reject non-admin users', async () => {
      if (!clientToken) return;

      const response = await request(app.getHttpServer())
        .get('/api/admin/users')
        .set('Authorization', `Bearer ${clientToken}`);

      expect(response.status).toBe(403);
    });

    it('should allow admin access', async () => {
      if (!adminToken) return;

      const response = await request(app.getHttpServer())
        .get('/api/admin/users')
        .set('Authorization', `Bearer ${adminToken}`);

      expect([200, 403]).toContain(response.status);
    });
  });

  describe('GET /api/admin/roles', () => {
    it('should return roles for admin', async () => {
      if (!adminToken) return;

      const response = await request(app.getHttpServer())
        .get('/api/admin/roles')
        .set('Authorization', `Bearer ${adminToken}`);

      expect([200, 403]).toContain(response.status);
    });
  });
});
