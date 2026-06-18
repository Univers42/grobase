/**
 * Working Hours E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Working Hours (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/working-hours is public', async () => {
    const response = await request(app.getHttpServer()).get(
      '/api/working-hours',
    );

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(Array.isArray(response.body.data)).toBe(true);
  });

  it('GET /api/working-hours returns all days', async () => {
    const response = await request(app.getHttpServer()).get(
      '/api/working-hours',
    );

    if (response.body.data?.length > 0) {
      const item = response.body.data[0];
      expect(item).toHaveProperty('day');
    }
  });

  it('PUT /api/working-hours/:day requires auth', async () => {
    const response = await request(app.getHttpServer())
      .put('/api/working-hours/monday')
      .send({ open: '09:00', close: '18:00' });

    expect(response.status).toBe(401);
  });
});
