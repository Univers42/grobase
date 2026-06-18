/**
 * Allergens E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Allergens (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/allergens is public', async () => {
    const response = await request(app.getHttpServer()).get('/api/allergens');

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(Array.isArray(response.body.data)).toBe(true);
  });

  it('GET /api/allergens returns allergen list', async () => {
    const response = await request(app.getHttpServer()).get('/api/allergens');

    if (response.body.data?.length > 0) {
      const item = response.body.data[0];
      expect(item).toHaveProperty('id');
      expect(item).toHaveProperty('name');
    }
  });

  it('GET /api/allergens/:id returns allergen', async () => {
    const list = await request(app.getHttpServer()).get('/api/allergens');

    if (list.body.data?.length > 0) {
      const id = list.body.data[0].id;
      const response = await request(app.getHttpServer()).get(
        `/api/allergens/${id}`,
      );

      expect(response.status).toBe(200);
      expect(response.body.data).toHaveProperty('name');
    }
  });

  it('POST /api/allergens requires auth', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/allergens')
      .send({ name: 'Test Allergen' });

    expect(response.status).toBe(401);
  });
});
