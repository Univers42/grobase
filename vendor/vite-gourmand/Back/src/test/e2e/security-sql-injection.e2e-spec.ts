/**
 * SQL Injection E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('SQL Injection Prevention (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  const sqlPayloads = [
    "' OR '1'='1",
    "'; DROP TABLE users; --",
    '1; DELETE FROM users',
    "' UNION SELECT * FROM users --",
    "admin'--",
    "1' OR '1' = '1",
    "' OR 1=1--",
    "'; EXEC xp_cmdshell('dir'); --",
    "1; UPDATE users SET role='admin'",
    "' AND 1=0 UNION SELECT password FROM users--",
  ];

  describe('Login endpoint', () => {
    sqlPayloads.forEach((payload, i) => {
      it(`rejects SQL injection in email #${i + 1}`, async () => {
        const response = await request(app.getHttpServer())
          .post('/api/auth/login')
          .send({ email: payload, password: 'test' });

        expect([400, 401]).toContain(response.status);
        expect(response.body.data?.accessToken).toBeUndefined();
      });

      it(`rejects SQL injection in password #${i + 1}`, async () => {
        const response = await request(app.getHttpServer())
          .post('/api/auth/login')
          .send({ email: 'test@test.com', password: payload });

        expect([400, 401]).toContain(response.status);
      });
    });
  });

  describe('Search/Filter endpoints', () => {
    sqlPayloads.forEach((payload, i) => {
      it(`rejects SQL injection in menu search #${i + 1}`, async () => {
        const response = await request(app.getHttpServer()).get(
          `/api/menus?search=${encodeURIComponent(payload)}`,
        );

        expect([200, 400]).toContain(response.status);
        // Should not crash or expose error details
        if (response.status === 400) {
          expect(response.body.message).not.toContain('SQL');
        }
      });
    });
  });

  describe('ID parameters', () => {
    // SQL injection payloads that should be rejected
    const idPayloads = [
      '1 OR 1=1',
      '1; DROP TABLE menus',
      "1' OR '1'='1",
      '-1 UNION SELECT * FROM users',
    ];

    idPayloads.forEach((payload, i) => {
      it(`rejects SQL injection in menu ID #${i + 1}`, async () => {
        const response = await request(app.getHttpServer()).get(
          `/api/menus/${encodeURIComponent(payload)}`,
        );

        expect([400, 404]).toContain(response.status);
      });

      it(`rejects SQL injection in dish ID #${i + 1}`, async () => {
        const response = await request(app.getHttpServer()).get(
          `/api/dishes/${encodeURIComponent(payload)}`,
        );

        expect([400, 404]).toContain(response.status);
      });
    });

    // Note: 0x31 may be parsed as valid integer (49 in hex = 0x31)
    // 1e1 may be parsed as scientific notation (10)
    // These are edge cases, not SQL injection
  });
});
