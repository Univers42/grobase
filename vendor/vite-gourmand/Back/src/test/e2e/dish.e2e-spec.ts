/**
 * Dish API E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Dish API (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  describe('GET /api/dishes', () => {
    it('should return dishes (public)', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/dishes')
        .expect(200);

      expect(response.body.success).toBe(true);
      expect(response.body.data).toHaveProperty('items');
      expect(response.body.data).toHaveProperty('meta');
    });

    it('should support pagination', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/dishes?page=1&limit=5')
        .expect(200);

      expect(response.body.success).toBe(true);
      expect(Array.isArray(response.body.data.items)).toBe(true);
    });
  });

  describe('GET /api/dishes/:id', () => {
    it('should return 404 for non-existent dish', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/dishes/99999')
        .expect(404);

      expect(response.body.success).toBe(false);
    });
  });
});
