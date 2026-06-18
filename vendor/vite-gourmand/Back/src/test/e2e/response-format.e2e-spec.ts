/**
 * Response Format E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Response Format (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('should wrap success responses in standard format', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({
        email: testUtils.uniqueEmail('response'),
        password: 'SecurePassword123!',
        firstName: 'ResponseTest',
        gdprConsent: true,
      });

    expect(response.status).toBe(201);
    expect(response.body).toHaveProperty('success', true);
    expect(response.body).toHaveProperty('statusCode', 201);
    expect(response.body).toHaveProperty('message');
    expect(response.body).toHaveProperty('data');
    expect(response.body).toHaveProperty('timestamp');
  });

  it('should include path in response', async () => {
    const response = await request(app.getHttpServer()).get('/api').expect(200);

    expect(response.body.success).toBe(true);
    expect(response.body).toHaveProperty('path');
  });

  it('should include CORS headers', async () => {
    const response = await request(app.getHttpServer()).get('/api').expect(200);

    expect(response.headers).toHaveProperty('access-control-allow-origin');
  });
});
