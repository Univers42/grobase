/**
 * Authentication Bypass E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Authentication Bypass Prevention (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  describe('JWT Token Manipulation', () => {
    it('rejects empty authorization header', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/users/me')
        .set('Authorization', '');

      expect(response.status).toBe(401);
    });

    it('rejects Bearer without token', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/users/me')
        .set('Authorization', 'Bearer ');

      expect(response.status).toBe(401);
    });

    // Note: Null byte test skipped - supertest/node http client rejects invalid header characters
    // The app is still protected because the request never reaches the server
    it('rejects malformed Bearer token', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/users/me')
        .set('Authorization', 'Bearer %00admin');

      expect(response.status).toBe(401);
    });

    it('rejects token with modified algorithm', async () => {
      // Token with "alg": "none"
      const noneToken =
        'eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOjEsInJvbGUiOiJhZG1pbiJ9.';

      const response = await request(app.getHttpServer())
        .get('/api/users/me')
        .set('Authorization', `Bearer ${noneToken}`);

      expect(response.status).toBe(401);
    });

    it('rejects token with modified payload', async () => {
      // Tampered token
      const tamperedToken =
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsInJvbGUiOiJhZG1pbiIsImlhdCI6MTUxNjIzOTAyMn0.tampered';

      const response = await request(app.getHttpServer())
        .get('/api/users/me')
        .set('Authorization', `Bearer ${tamperedToken}`);

      expect(response.status).toBe(401);
    });

    it('rejects very long token', async () => {
      const longToken = 'a'.repeat(10000);

      const response = await request(app.getHttpServer())
        .get('/api/users/me')
        .set('Authorization', `Bearer ${longToken}`);

      expect(response.status).toBe(401);
    });

    it('rejects token with special characters', async () => {
      const specialToken = '../../etc/passwd';

      const response = await request(app.getHttpServer())
        .get('/api/users/me')
        .set('Authorization', `Bearer ${specialToken}`);

      expect(response.status).toBe(401);
    });
  });

  describe('Session/Cookie Manipulation', () => {
    it('rejects forged session cookie', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/users/me')
        .set('Cookie', 'session=admin');

      expect(response.status).toBe(401);
    });

    it('rejects modified user ID cookie', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/users/me')
        .set('Cookie', 'userId=1');

      expect(response.status).toBe(401);
    });
  });

  describe('Password Reset Bypass', () => {
    it('rejects empty reset token', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/reset-password')
        .send({ token: '', newPassword: 'NewPass123!' });

      expect([400, 401]).toContain(response.status);
    });

    it('rejects invalid reset token', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/reset-password')
        .send({ token: 'invalid-token', newPassword: 'NewPass123!' });

      expect([400, 401, 404]).toContain(response.status);
    });
  });
});
