/**
 * NoSQL Injection Prevention E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('NoSQL Injection Prevention (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  describe('MongoDB-style Injection', () => {
    const nosqlPayloads = [
      { $gt: '' },
      { $ne: '' },
      { $regex: '.*' },
      { $where: 'function() { return true; }' },
      { $or: [{ a: 1 }] },
      { $exists: true },
    ];

    nosqlPayloads.forEach((payload, i) => {
      it(`rejects NoSQL injection in email #${i + 1}`, async () => {
        const response = await request(app.getHttpServer())
          .post('/api/auth/login')
          .send({ email: payload, password: 'test' });

        expect([400, 401]).toContain(response.status);
      });

      it(`rejects NoSQL injection in password #${i + 1}`, async () => {
        const response = await request(app.getHttpServer())
          .post('/api/auth/login')
          .send({ email: 'test@test.com', password: payload });

        expect([400, 401]).toContain(response.status);
      });
    });
  });

  describe('JSON Injection', () => {
    it('handles malformed JSON body', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .set('Content-Type', 'application/json')
        .send('{"email": "test@test.com", "password": }');

      expect([400, 500]).toContain(response.status);
    });

    it('handles deeply nested JSON', async () => {
      let nested: any = { a: 'b' };
      for (let i = 0; i < 100; i++) {
        nested = { nested };
      }

      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send(nested);

      expect([400, 413]).toContain(response.status);
    });

    it('handles prototype pollution attempt', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({
          email: 'test@test.com',
          password: 'test',
          __proto__: { admin: true },
          constructor: { prototype: { admin: true } },
        });

      expect([400, 401]).toContain(response.status);
    });
  });
});
