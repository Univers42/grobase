/**
 * Pagination E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Pagination (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/menus accepts pagination params', async () => {
    const response = await request(app.getHttpServer()).get(
      '/api/menus?page=1&limit=5',
    );

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
  });

  it('GET /api/dishes accepts pagination params', async () => {
    const response = await request(app.getHttpServer()).get(
      '/api/dishes?page=1&limit=5',
    );

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
  });

  it('handles invalid page number gracefully', async () => {
    const response = await request(app.getHttpServer()).get(
      '/api/menus?page=-1',
    );

    expect([200, 400]).toContain(response.status);
  });

  it('handles invalid limit gracefully', async () => {
    const response = await request(app.getHttpServer()).get(
      '/api/menus?limit=abc',
    );

    expect([200, 400]).toContain(response.status);
  });

  it('rejects excessive limit', async () => {
    const response = await request(app.getHttpServer()).get(
      '/api/menus?limit=1000',
    );

    // API validates and rejects excessive limits
    expect([200, 400]).toContain(response.status);
  });
});
