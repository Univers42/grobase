/**
 * Auth Login E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Auth Login (e2e)', () => {
  let app: INestApplication;
  let testEmail: string;
  const testPassword = 'SecurePassword123!';

  beforeAll(async () => {
    app = await createTestApp();
    testEmail = testUtils.uniqueEmail('login');

    await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({ email: testEmail, password: testPassword, firstName: 'Login', gdprConsent: true });
  });

  afterAll(async () => {
    await app.close();
  });

  it('should login with valid credentials', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email: testEmail, password: testPassword });

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(response.body.data).toHaveProperty('accessToken');
  });

  it('should reject wrong password', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email: testEmail, password: 'WrongPassword123!' });

    expect(response.status).toBe(401);
    expect(response.body.success).toBe(false);
  });

  it('should reject non-existent user', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email: 'nonexistent@test.com', password: testPassword });

    expect(response.status).toBe(401);
    expect(response.body.success).toBe(false);
  });

  it('should reject empty credentials', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({});

    expect(response.status).toBe(400);
  });
});
