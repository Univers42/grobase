/**
 * API Response Contract Tests E2E
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('API Response Contract (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  describe('Success Response Format', () => {
    it('GET /api has success format', async () => {
      const response = await request(app.getHttpServer()).get('/api');

      expect(response.body).toHaveProperty('success');
      expect(response.body.success).toBe(true);
      expect(response.body).toHaveProperty('data');
    });

    it('GET /api/menus has success format', async () => {
      const response = await request(app.getHttpServer()).get('/api/menus');

      expect(response.body).toHaveProperty('success');
      expect(response.body.success).toBe(true);
    });

    it('Login response has token', async () => {
      const email = testUtils.uniqueEmail('token');
      await request(app.getHttpServer())
        .post('/api/auth/register')
        .send({ email, password: 'Test123!', firstName: 'Token', gdprConsent: true });

      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({ email, password: 'Test123!' });

      expect(response.body.success).toBe(true);
      expect(response.body.data).toHaveProperty('accessToken');
    });
  });

  describe('Error Response Format', () => {
    it('400 has error format', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({});

      expect(response.status).toBe(400);
      expect(response.body).toHaveProperty('success');
      expect(response.body.success).toBe(false);
    });

    it('401 has error format', async () => {
      const response = await request(app.getHttpServer()).get('/api/users/me');

      expect(response.status).toBe(401);
      expect(response.body.success).toBe(false);
    });

    it('404 has error format', async () => {
      const response = await request(app.getHttpServer()).get(
        '/api/menus/99999',
      );

      expect(response.status).toBe(404);
      expect(response.body.success).toBe(false);
    });
  });

  describe('Content-Type Headers', () => {
    it('returns JSON content type', async () => {
      const response = await request(app.getHttpServer()).get('/api');

      expect(response.headers['content-type']).toContain('application/json');
    });

    it('errors return JSON content type', async () => {
      const response = await request(app.getHttpServer()).get(
        '/api/menus/invalid',
      );

      expect(response.headers['content-type']).toContain('application/json');
    });
  });

  describe('HTTP Status Codes', () => {
    it('successful GET returns 200', async () => {
      const response = await request(app.getHttpServer()).get('/api');
      expect(response.status).toBe(200);
    });

    it('successful POST registration returns 201', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/register')
        .send({
          email: testUtils.uniqueEmail('status'),
          password: 'Test123!',
          firstName: 'Status',
          gdprConsent: true,
        });
      expect([200, 201]).toContain(response.status);
    });

    it('validation error returns 400', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({ email: 'invalid' });
      expect(response.status).toBe(400);
    });

    it('unauthorized returns 401', async () => {
      const response = await request(app.getHttpServer()).get('/api/users/me');
      expect(response.status).toBe(401);
    });

    it('not found returns 404', async () => {
      const response = await request(app.getHttpServer()).get(
        '/api/nonexistent',
      );
      expect(response.status).toBe(404);
    });
  });
});
