/**
 * Authorization Escalation E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Authorization Escalation Prevention (e2e)', () => {
  let app: INestApplication;
  let clientToken: string;

  beforeAll(async () => {
    app = await createTestApp();
    const email = testUtils.uniqueEmail('authz');
    await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({ email, password: 'Test123!', firstName: 'Client', gdprConsent: true });

    const login = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email, password: 'Test123!' });

    clientToken = login.body.data?.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  describe('Admin Endpoint Protection', () => {
    it('blocks client from admin stats', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/admin/stats')
        .set('Authorization', `Bearer ${clientToken}`);

      expect([401, 403]).toContain(response.status);
    });

    it('blocks client from user list', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/users')
        .set('Authorization', `Bearer ${clientToken}`);

      expect([401, 403]).toContain(response.status);
    });

    it('blocks client from analytics', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/analytics/stats')
        .set('Authorization', `Bearer ${clientToken}`);

      expect([401, 403]).toContain(response.status);
    });
  });

  describe('Manager Endpoint Protection', () => {
    it('blocks client from creating menu', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/menus')
        .set('Authorization', `Bearer ${clientToken}`)
        .send({ name: 'Hacked Menu' });

      expect([401, 403]).toContain(response.status);
    });

    it('blocks client from creating dish', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/dishes')
        .set('Authorization', `Bearer ${clientToken}`)
        .send({ name: 'Hacked Dish', price: 0 });

      expect([401, 403]).toContain(response.status);
    });

    it('blocks client from updating menu', async () => {
      const response = await request(app.getHttpServer())
        .put('/api/menus/1')
        .set('Authorization', `Bearer ${clientToken}`)
        .send({ name: 'Hacked' });

      expect([401, 403]).toContain(response.status);
    });

    it('blocks client from deleting menu', async () => {
      const response = await request(app.getHttpServer())
        .delete('/api/menus/1')
        .set('Authorization', `Bearer ${clientToken}`);

      expect([401, 403]).toContain(response.status);
    });
  });

  describe('Role Manipulation Prevention', () => {
    it('blocks role change in profile update', async () => {
      const response = await request(app.getHttpServer())
        .put('/api/users/me')
        .set('Authorization', `Bearer ${clientToken}`)
        .send({ role: 'admin' });

      expect([200, 400]).toContain(response.status);
      // If accepted, role should not be changed
      const profile = await request(app.getHttpServer())
        .get('/api/users/me')
        .set('Authorization', `Bearer ${clientToken}`);

      if (profile.body.data?.role) {
        expect(profile.body.data.role).not.toBe('admin');
      }
    });

    it('blocks role change in registration', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/register')
        .send({
          email: testUtils.uniqueEmail('roletest'),
          password: 'Test123!',
          firstName: 'Test',
          role: 'admin',
          gdprConsent: true,
        });

      expect([200, 201, 400]).toContain(response.status);
      if (response.body.data?.role) {
        expect(response.body.data.role).not.toBe('admin');
      }
    });
  });

  describe('IDOR Prevention', () => {
    it('blocks access to other user orders', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/orders/1')
        .set('Authorization', `Bearer ${clientToken}`);

      expect([403, 404]).toContain(response.status);
    });

    it('blocks update of other user profile', async () => {
      const response = await request(app.getHttpServer())
        .put('/api/users/1')
        .set('Authorization', `Bearer ${clientToken}`)
        .send({ firstName: 'Hacked', gdprConsent: true });

      expect([401, 403, 404]).toContain(response.status);
    });
  });
});
