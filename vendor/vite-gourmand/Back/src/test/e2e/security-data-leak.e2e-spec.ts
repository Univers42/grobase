/**
 * Data Leak Prevention E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Data Leak Prevention (e2e)', () => {
  let app: INestApplication;
  let authToken: string;

  beforeAll(async () => {
    app = await createTestApp();
    const email = testUtils.uniqueEmail('dataleak');
    await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({ email, password: 'Test123!', firstName: 'Leak', gdprConsent: true });

    const login = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email, password: 'Test123!' });

    authToken = login.body.data?.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  describe('Password Exposure', () => {
    it('does not expose password in login response', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({
          email: testUtils.uniqueEmail('pwtest'),
          password: 'Test123!',
        });

      expect(response.body.data?.password).toBeUndefined();
      expect(response.body.data?.passwordHash).toBeUndefined();
      expect(JSON.stringify(response.body)).not.toContain('passwordHash');
    });

    it('does not expose password in profile', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/users/me')
        .set('Authorization', `Bearer ${authToken}`);

      if (response.body.data) {
        expect(response.body.data.password).toBeUndefined();
        expect(response.body.data.passwordHash).toBeUndefined();
      }
    });
  });

  describe('Error Message Security', () => {
    it('does not expose SQL errors', async () => {
      const response = await request(app.getHttpServer()).get(
        "/api/menus/' OR 1=1--",
      );

      expect(response.text).not.toContain('SELECT');
      expect(response.text).not.toContain('FROM');
      expect(response.text).not.toContain('WHERE');
    });

    it('does not expose stack traces', async () => {
      const response = await request(app.getHttpServer()).get(
        '/api/nonexistent-endpoint',
      );

      expect(response.text).not.toContain('at Object.');
      expect(response.text).not.toContain('.ts:');
      expect(response.text).not.toContain('node_modules');
    });

    it('does not expose database structure', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({ email: '"; SELECT * FROM pg_tables--', password: 'x' });

      expect(response.text).not.toContain('pg_tables');
      expect(response.text).not.toContain('tablename');
    });
  });

  describe('Internal Path Exposure', () => {
    it('does not expose file paths', async () => {
      const response = await request(app.getHttpServer()).get('/api');

      expect(response.text).not.toContain('/home/');
      expect(response.text).not.toContain('/var/');
      expect(response.text).not.toContain('C:\\');
    });

    it('does not expose environment variables', async () => {
      const response = await request(app.getHttpServer()).get('/api');

      expect(response.text).not.toContain('DATABASE_URL');
      expect(response.text).not.toContain('JWT_SECRET');
    });
  });

  describe('Enumeration Prevention', () => {
    it('returns consistent error for user not found', async () => {
      const response1 = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({ email: 'nonexistent@test.com', password: 'wrong' });

      const response2 = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({ email: 'another@test.com', password: 'wrong' });

      expect(response1.status).toBe(response2.status);
    });
  });
});
