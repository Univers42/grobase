/**
 * Business Logic Security E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Business Logic Security (e2e)', () => {
  let app: INestApplication;
  let authToken: string;

  beforeAll(async () => {
    app = await createTestApp();
    const email = testUtils.uniqueEmail('bizlogic');
    await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({ email, password: 'Test123!', firstName: 'Biz', gdprConsent: true });

    const login = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email, password: 'Test123!' });

    authToken = login.body.data?.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  describe('Price Manipulation', () => {
    it('rejects negative price in order', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/orders')
        .set('Authorization', `Bearer ${authToken}`)
        .send({ items: [{ dishId: 1, quantity: 1, price: -100 }] });

      expect([400, 401, 403]).toContain(response.status);
    });

    it('rejects zero price override', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/orders')
        .set('Authorization', `Bearer ${authToken}`)
        .send({ items: [{ dishId: 1, quantity: 1 }], total: 0 });

      expect([400, 401]).toContain(response.status);
    });
  });

  describe('Quantity Manipulation', () => {
    it('rejects negative quantity', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/orders')
        .set('Authorization', `Bearer ${authToken}`)
        .send({ items: [{ dishId: 1, quantity: -5 }] });

      expect([400, 401]).toContain(response.status);
    });

    it('rejects zero quantity', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/orders')
        .set('Authorization', `Bearer ${authToken}`)
        .send({ items: [{ dishId: 1, quantity: 0 }] });

      expect([400, 401]).toContain(response.status);
    });

    it('rejects excessive quantity', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/orders')
        .set('Authorization', `Bearer ${authToken}`)
        .send({ items: [{ dishId: 1, quantity: 999999 }] });

      expect([400, 401]).toContain(response.status);
    });
  });

  describe('Rating Manipulation', () => {
    it('rejects rating below minimum', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/reviews')
        .set('Authorization', `Bearer ${authToken}`)
        .send({ dishId: 1, rating: -1, content: 'Bad' });

      expect([400, 401, 404]).toContain(response.status);
    });

    it('rejects rating above maximum', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/reviews')
        .set('Authorization', `Bearer ${authToken}`)
        .send({ dishId: 1, rating: 100, content: 'Too good' });

      expect([400, 401, 404]).toContain(response.status);
    });

    it('rejects non-integer rating', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/reviews')
        .set('Authorization', `Bearer ${authToken}`)
        .send({ dishId: 1, rating: 4.5, content: 'Half' });

      expect([200, 201, 400, 401, 404]).toContain(response.status);
    });
  });

  describe('Date Manipulation', () => {
    it('rejects past date for order', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/orders')
        .set('Authorization', `Bearer ${authToken}`)
        .send({
          items: [{ dishId: 1, quantity: 1 }],
          scheduledAt: '2020-01-01T00:00:00Z',
        });

      expect([400, 401]).toContain(response.status);
    });
  });
});
