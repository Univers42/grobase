/**
 * App Controller E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('AppController (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('/api (GET) returns Hello World', async () => {
    const response = await request(app.getHttpServer()).get('/api').expect(200);

    expect(response.body.success).toBe(true);
    expect(response.body.data).toBe('Hello World!');
  });

  it('/api/health returns OK', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/health')
      .expect(200);

    expect(response.body.success).toBe(true);
  });
});
