/**
 * Diets E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Diets (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/diets is public', async () => {
    const response = await request(app.getHttpServer()).get('/api/diets');

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(Array.isArray(response.body.data)).toBe(true);
  });

  it('GET /api/diets returns diet list', async () => {
    const response = await request(app.getHttpServer()).get('/api/diets');

    if (response.body.data?.length > 0) {
      const item = response.body.data[0];
      expect(item).toHaveProperty('id');
      expect(item).toHaveProperty('name');
    }
  });

  it('GET /api/diets/:id returns diet', async () => {
    const list = await request(app.getHttpServer()).get('/api/diets');

    if (list.body.data?.length > 0) {
      const id = list.body.data[0].id;
      const response = await request(app.getHttpServer()).get(
        `/api/diets/${id}`,
      );

      expect(response.status).toBe(200);
      expect(response.body.data).toHaveProperty('name');
    }
  });

  it('POST /api/diets requires auth', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/diets')
      .send({ name: 'Test Diet' });

    expect(response.status).toBe(401);
  });
});
