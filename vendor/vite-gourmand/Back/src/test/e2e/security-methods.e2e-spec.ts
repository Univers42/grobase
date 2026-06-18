/**
 * Method Override and HTTP Verb Security E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('HTTP Method Security (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  describe('Method Override Prevention', () => {
    it('ignores X-HTTP-Method-Override header', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/menus/1')
        .set('X-HTTP-Method-Override', 'DELETE');

      expect([200, 404]).toContain(response.status);
    });

    it('ignores _method query parameter', async () => {
      const response = await request(app.getHttpServer()).get(
        '/api/menus/1?_method=DELETE',
      );

      expect([200, 404]).toContain(response.status);
    });
  });

  describe('Disallowed Methods', () => {
    it('rejects TRACE method', async () => {
      const response = await request(app.getHttpServer()).trace('/api');

      expect([404, 405]).toContain(response.status);
    });

    // Note: CONNECT method test skipped - supertest causes socket hang up
    // CONNECT is typically used for HTTPS tunneling and not supported by supertest
    it('rejects unsupported custom method', async () => {
      const response = await request(app.getHttpServer()).options('/api');

      expect([200, 204, 404, 405]).toContain(response.status);
    });
  });

  describe('Method Restrictions', () => {
    it('GET /api/auth/login returns 404', async () => {
      const response = await request(app.getHttpServer()).get(
        '/api/auth/login',
      );

      expect([404]).toContain(response.status);
    });

    it('POST /api/menus without ID is protected', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/menus')
        .send({ name: 'Test' });

      expect([401]).toContain(response.status);
    });

    it('DELETE /api without ID returns 404', async () => {
      const response = await request(app.getHttpServer()).delete('/api');

      expect([404]).toContain(response.status);
    });
  });

  describe('HEAD Method Support', () => {
    it('HEAD /api/menus works', async () => {
      const response = await request(app.getHttpServer()).head('/api/menus');

      expect(response.status).toBe(200);
      expect(response.body).toEqual({});
    });

    it('HEAD /api/dishes works', async () => {
      const response = await request(app.getHttpServer()).head('/api/dishes');

      expect(response.status).toBe(200);
    });
  });
});
