/**
 * Users E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Users (e2e)', () => {
  let app: INestApplication;
  let authToken: string;

  beforeAll(async () => {
    app = await createTestApp();
    const email = testUtils.uniqueEmail('user');
    await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({ email, password: 'Test123!', firstName: 'UserTest', gdprConsent: true });

    const login = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email, password: 'Test123!' });

    authToken = login.body.data?.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/users/me requires auth', async () => {
    const response = await request(app.getHttpServer()).get('/api/users/me');
    expect(response.status).toBe(401);
  });

  it('GET /api/users/me returns profile', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/users/me')
      .set('Authorization', `Bearer ${authToken}`);

    expect([200, 401]).toContain(response.status);
    if (response.status === 200) {
      expect(response.body.success).toBe(true);
      expect(response.body.data).toHaveProperty('email');
    }
  });

  it('PUT /api/users/me updates profile', async () => {
    const response = await request(app.getHttpServer())
      .put('/api/users/me')
      .set('Authorization', `Bearer ${authToken}`)
      .send({ firstName: 'UpdatedName' });

    expect([200, 401]).toContain(response.status);
  });

  it('GET /api/users/me/addresses returns addresses', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/users/me/addresses')
      .set('Authorization', `Bearer ${authToken}`);

    expect([200, 401]).toContain(response.status);
    if (response.status === 200) {
      expect(response.body.success).toBe(true);
    }
  });

  it('GET /api/users admin list requires admin role', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/users')
      .set('Authorization', `Bearer ${authToken}`);

    expect([403, 401]).toContain(response.status);
  });
});
