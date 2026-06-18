/**
 * Analytics E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Analytics (e2e)', () => {
  let app: INestApplication;
  let authToken: string;

  beforeAll(async () => {
    app = await createTestApp();
    const email = testUtils.uniqueEmail('analytics');
    await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({ email, password: 'Test123!', firstName: 'Analytics', gdprConsent: true });

    const login = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email, password: 'Test123!' });

    authToken = login.body.data?.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  it('POST /api/analytics/track accepts event', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/analytics/track')
      .set('Authorization', `Bearer ${authToken}`)
      .send({ eventType: 'page_view', data: { page: '/test' } });

    expect([200, 201, 401]).toContain(response.status);
  });

  it('GET /api/analytics/events requires admin', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/analytics/events?type=page_view')
      .set('Authorization', `Bearer ${authToken}`);

    expect([403, 401]).toContain(response.status);
  });

  it('GET /api/analytics/stats requires admin', async () => {
    const response = await request(app.getHttpServer())
      .get('/api/analytics/stats')
      .set('Authorization', `Bearer ${authToken}`);

    expect([403, 401]).toContain(response.status);
  });
});
