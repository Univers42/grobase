/**
 * Error Handling E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Error Handling (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('should return consistent 401 error format', async () => {
    const response = await request(app.getHttpServer()).get('/api/auth/me');

    expect(response.status).toBe(401);
    expect(response.body).toHaveProperty('success', false);
    expect(response.body).toHaveProperty('statusCode', 401);
    expect(response.body).toHaveProperty('message');
    expect(response.body).toHaveProperty('timestamp');
  });

  it('should return consistent 400 error format', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({});

    expect(response.status).toBe(400);
    expect(response.body).toHaveProperty('success', false);
    expect(response.body).toHaveProperty('statusCode', 400);
  });

  it('should return consistent 404 error format', async () => {
    const response = await request(app.getHttpServer()).get(
      '/api/nonexistent-route',
    );

    expect(response.status).toBe(404);
    expect(response.body).toHaveProperty('success', false);
    expect(response.body).toHaveProperty('statusCode', 404);
  });

  it('should not expose stack traces', async () => {
    const response = await request(app.getHttpServer()).get(
      '/api/nonexistent-route',
    );

    expect(response.body.stack).toBeUndefined();
  });
});
