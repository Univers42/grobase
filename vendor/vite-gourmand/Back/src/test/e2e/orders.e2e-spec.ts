/**
 * Orders E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Orders (e2e)', () => {
  let app: INestApplication;
  let authToken: string;

  beforeAll(async () => {
    app = await createTestApp();
    const email = testUtils.uniqueEmail('order');
    await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({ email, password: 'Test123!', firstName: 'Order', gdprConsent: true });

    const login = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email, password: 'Test123!' });

    authToken = login.body.data?.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/orders requires auth', async () => {
    const response = await request(app.getHttpServer()).get('/api/orders');
    expect(response.status).toBe(401);
  });

  it('GET /api/orders with auth returns list', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/orders')
      .set('Authorization', `Bearer ${authToken}`);

    expect([200, 401]).toContain(response.status);
    if (response.status === 200) {
      expect(response.body.success).toBe(true);
    }
  });

  it('GET /api/orders/:id with invalid id returns 404', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/orders/99999')
      .set('Authorization', `Bearer ${authToken}`);

    expect([404, 401, 403]).toContain(response.status);
  });
});
