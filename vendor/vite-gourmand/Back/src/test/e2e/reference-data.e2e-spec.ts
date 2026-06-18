/**
 * Reference Data API E2E Tests (Diets, Themes, Allergens)
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Reference Data (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  describe('GET /api/diets', () => {
    it('should return all diets', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/diets')
        .expect(200);

      expect(response.body.success).toBe(true);
      expect(Array.isArray(response.body.data)).toBe(true);
    });
  });

  describe('GET /api/themes', () => {
    it('should return all themes', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/themes')
        .expect(200);

      expect(response.body.success).toBe(true);
      expect(Array.isArray(response.body.data)).toBe(true);
    });
  });

  describe('GET /api/allergens', () => {
    it('should return all allergens', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/allergens')
        .expect(200);

      expect(response.body.success).toBe(true);
      expect(Array.isArray(response.body.data)).toBe(true);
    });
  });

  describe('GET /api/working-hours', () => {
    it('should return working hours', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/working-hours')
        .expect(200);

      expect(response.body.success).toBe(true);
    });
  });
});
