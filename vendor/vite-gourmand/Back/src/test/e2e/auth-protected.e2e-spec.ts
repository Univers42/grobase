/**
 * Protected Routes E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Protected Routes (e2e)', () => {
  let app: INestApplication;
  let accessToken: string;

  beforeAll(async () => {
    app = await createTestApp();

    const email = testUtils.uniqueEmail('protected');
    await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({ email, password: 'SecurePassword123!', firstName: 'Protected', gdprConsent: true });

    const loginRes = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email, password: 'SecurePassword123!' });

    accessToken = loginRes.body.data?.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  it('should reject /api/auth/me without token', async () => {
    const response = await request(app.getHttpServer()).get('/api/auth/me');
    expect(response.status).toBe(401);
  });

  it('should reject invalid token', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/auth/me')
      .set('Authorization', 'Bearer invalid-token');

    expect(response.status).toBe(401);
  });

  it('should return user with valid token', async () => {
    if (!accessToken) return;

    const response = await request(app.getHttpServer())
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${accessToken}`);

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(response.body.data).toHaveProperty('email');
  });
});
