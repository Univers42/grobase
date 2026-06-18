/**
 * Themes E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Themes (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/themes is public', async () => {
    const response = await request(app.getHttpServer()).get('/api/themes');

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(Array.isArray(response.body.data)).toBe(true);
  });

  it('GET /api/themes/:id returns theme', async () => {
    const listRes = await request(app.getHttpServer()).get('/api/themes');

    if (listRes.body.data?.length > 0) {
      const id = listRes.body.data[0].id;
      const response = await request(app.getHttpServer()).get(
        `/api/themes/${id}`,
      );

      expect(response.status).toBe(200);
      expect(response.body.success).toBe(true);
      expect(response.body.data).toHaveProperty('id');
    }
  });

  it('GET /api/themes/:id invalid returns 404', async () => {
    const response = await request(app.getHttpServer()).get(
      '/api/themes/99999',
    );

    expect(response.status).toBe(404);
  });

  it('POST /api/themes requires auth', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/themes')
      .send({ name: 'Test Theme' });

    expect(response.status).toBe(401);
  });
});
