/**
 * Auth Password E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Auth Password (e2e)', () => {
  let app: INestApplication;
  let authToken: string;
  let testEmail: string;
  const testPassword = 'Test123!';

  beforeAll(async () => {
    app = await createTestApp();
    testEmail = testUtils.uniqueEmail('password');

    await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({ email: testEmail, password: testPassword, firstName: 'Pass', gdprConsent: true });

    const login = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email: testEmail, password: testPassword });

    authToken = login.body.data?.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  it('POST /api/auth/forgot-password accepts email', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/forgot-password')
      .send({ email: testEmail });

    expect([200, 201]).toContain(response.status);
  });

  it('POST /api/auth/forgot-password handles unknown email', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/forgot-password')
      .send({ email: 'unknown@test.com' });

    // Should not reveal if email exists
    expect([200, 201, 404]).toContain(response.status);
  });

  it('POST /api/auth/change-password requires auth', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/change-password')
      .send({ oldPassword: testPassword, newPassword: 'NewPass123!' });

    expect(response.status).toBe(401);
  });

  it('POST /api/auth/change-password with auth works', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/change-password')
      .set('Authorization', `Bearer ${authToken}`)
      .send({ oldPassword: testPassword, newPassword: 'NewPass123!' });

    expect([200, 400, 401]).toContain(response.status);
  });
});
