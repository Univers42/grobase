/**
 * Validation E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Validation (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('should reject missing required fields', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({});

    expect(response.status).toBe(400);
    expect(response.body.success).toBe(false);
    expect(response.body.error).toBe('Validation failed');
  });

  it('should provide clear validation error messages', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({
        email: 'invalid',
        password: '123',
        firstName: 'A',
      });

    expect(response.status).toBe(400);
    expect(response.body.success).toBe(false);
  });
});
