/**
 * Dish CRUD E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Dish CRUD (e2e)', () => {
  let app: INestApplication;
  let authToken: string;

  beforeAll(async () => {
    app = await createTestApp();
    const email = testUtils.uniqueEmail('dish-crud');
    await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({ email, password: 'Test123!', firstName: 'DishTest', gdprConsent: true });

    const login = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email, password: 'Test123!' });

    authToken = login.body.data?.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/dishes is public', async () => {
    const response = await request(app.getHttpServer()).get('/api/dishes');

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
  });

  it('GET /api/dishes returns data', async () => {
    const response = await request(app.getHttpServer()).get('/api/dishes');

    expect(response.body.data).toBeDefined();
  });

  it('GET /api/dishes/:id returns dish details', async () => {
    const list = await request(app.getHttpServer()).get('/api/dishes');

    if (list.body.data?.length > 0) {
      const id = list.body.data[0].id;
      const response = await request(app.getHttpServer()).get(
        `/api/dishes/${id}`,
      );

      expect(response.status).toBe(200);
      expect(response.body.data).toHaveProperty('name');
    }
  });

  it('POST /api/dishes requires admin role', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/dishes')
      .set('Authorization', `Bearer ${authToken}`)
      .send({ name: 'Test Dish', price: 10.99 });

    expect([403, 401]).toContain(response.status);
  });

  it('PUT /api/dishes/:id requires admin role', async () => {
    const response = await request(app.getHttpServer())
      .put('/api/dishes/1')
      .set('Authorization', `Bearer ${authToken}`)
      .send({ name: 'Updated Dish' });

    expect([403, 401]).toContain(response.status);
  });

  it('DELETE /api/dishes/:id requires admin role', async () => {
    const response = await request(app.getHttpServer())
      .delete('/api/dishes/1')
      .set('Authorization', `Bearer ${authToken}`);

    expect([403, 401]).toContain(response.status);
  });
});
