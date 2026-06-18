/**
 * Auth Registration E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Auth Registration (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('should register a new user', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({
        email: testUtils.uniqueEmail('register'),
        password: 'SecurePassword123!',
        firstName: 'Test',
        gdprConsent: true,
      });

    expect(response.status).toBe(201);
    expect(response.body.success).toBe(true);
    expect(response.body.data).toHaveProperty('accessToken');
    expect(response.body.data).toHaveProperty('user');
  });

  it('should reject invalid email', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({
        email: 'invalid-email',
        password: 'SecurePassword123!',
        firstName: 'Test',
      });

    expect(response.status).toBe(400);
    expect(response.body.success).toBe(false);
  });

  it('should reject short password', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({
        email: testUtils.uniqueEmail('short'),
        password: '123',
        firstName: 'Test',
      });

    expect(response.status).toBe(400);
    expect(response.body.success).toBe(false);
  });

  it('should reject missing fields', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({});

    expect(response.status).toBe(400);
    expect(response.body.success).toBe(false);
  });
});
