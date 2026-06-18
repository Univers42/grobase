/**
 * Menu CRUD E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Menu CRUD (e2e)', () => {
  let app: INestApplication;
  let authToken: string;

  beforeAll(async () => {
    app = await createTestApp();
    const email = testUtils.uniqueEmail('menu-crud');
    await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({ email, password: 'Test123!', firstName: 'MenuTest', gdprConsent: true });

    const login = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email, password: 'Test123!' });

    authToken = login.body.data?.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/menus is public', async () => {
    const response = await request(app.getHttpServer()).get('/api/menus');

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
  });

  it('GET /api/menus returns data', async () => {
    const response = await request(app.getHttpServer()).get('/api/menus');

    expect(response.body.data).toBeDefined();
  });

  it('GET /api/menus/:id returns menu details', async () => {
    const list = await request(app.getHttpServer()).get('/api/menus');

    if (list.body.data?.length > 0) {
      const id = list.body.data[0].id;
      const response = await request(app.getHttpServer()).get(
        `/api/menus/${id}`,
      );

      expect(response.status).toBe(200);
      expect(response.body.data).toHaveProperty('name');
    }
  });

  it('POST /api/menus requires admin role', async () => {
    const response = await request(app.getHttpServer())
      .post('/api/menus')
      .set('Authorization', `Bearer ${authToken}`)
      .send({ name: 'Test Menu', description: 'Test' });

    expect([403, 401]).toContain(response.status);
  });

  it('PUT /api/menus/:id requires admin role', async () => {
    const response = await request(app.getHttpServer())
      .put('/api/menus/1')
      .set('Authorization', `Bearer ${authToken}`)
      .send({ name: 'Updated Menu' });

    expect([403, 401]).toContain(response.status);
  });

  it('DELETE /api/menus/:id requires admin role', async () => {
    const response = await request(app.getHttpServer())
      .delete('/api/menus/1')
      .set('Authorization', `Bearer ${authToken}`);

    expect([403, 401]).toContain(response.status);
  });
});
