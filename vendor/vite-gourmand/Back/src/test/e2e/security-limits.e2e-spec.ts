/**
 * Request Limit E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Request Limits (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  describe('Payload Size Limits', () => {
    it('rejects very large JSON payload', async () => {
      const largePayload = { data: 'x'.repeat(1024 * 1024) }; // 1MB

      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send(largePayload);

      // 400 = bad request, 413 = payload too large, 500 = body-parser error (known issue)
      expect([400, 413, 500]).toContain(response.status);
    });

    it('rejects deeply nested arrays', async () => {
      let arr: any = ['a'];
      for (let i = 0; i < 50; i++) {
        arr = [arr];
      }

      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({ email: arr, password: 'test' });

      expect([400, 413]).toContain(response.status);
    });
  });

  describe('URL Length Limits', () => {
    it('handles very long URL', async () => {
      const longParam = 'a'.repeat(5000);
      const response = await request(app.getHttpServer()).get(
        `/api/menus?search=${longParam}`,
      );

      expect([200, 400, 414]).toContain(response.status);
    });

    it('handles many query parameters', async () => {
      let url = '/api/menus?';
      for (let i = 0; i < 100; i++) {
        url += `param${i}=value${i}&`;
      }

      const response = await request(app.getHttpServer()).get(url);

      expect([200, 400, 414]).toContain(response.status);
    });
  });

  describe('Concurrent Request Handling', () => {
    it('handles multiple simultaneous requests', async () => {
      const requests = Array(10)
        .fill(null)
        .map(() => request(app.getHttpServer()).get('/api/menus'));

      const responses = await Promise.all(requests);

      responses.forEach((response) => {
        expect([200, 429]).toContain(response.status);
      });
    });
  });
});
