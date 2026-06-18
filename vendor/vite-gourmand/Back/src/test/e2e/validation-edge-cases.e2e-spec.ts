/**
 * Input Validation Edge Cases E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('Input Validation Edge Cases (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  describe('Email Validation', () => {
    const invalidEmails = [
      'notanemail',
      '@nodomain.com',
      'spaces in@email.com',
      'email@',
      'email@.com',
      'email@domain.',
      'email@@domain.com',
      '.email@domain.com',
      'email.@domain.com',
      'email@domain..com',
      'email@-domain.com',
      '<script>@evil.com',
      'email@domain.com<script>',
    ];

    invalidEmails.forEach((email, i) => {
      it(`rejects invalid email format #${i + 1}: ${email.slice(0, 20)}`, async () => {
        const response = await request(app.getHttpServer())
          .post('/api/auth/register')
          .send({ email, password: 'Test123!', firstName: 'Test', gdprConsent: true });

        expect(response.status).toBe(400);
      });
    });
  });

  describe('Password Validation', () => {
    const weakPasswords = ['123', 'abc'];

    weakPasswords.forEach((password, i) => {
      it(`rejects weak password #${i + 1}`, async () => {
        const response = await request(app.getHttpServer())
          .post('/api/auth/register')
          .send({ email: testUtils.uniqueEmail(`weak${i}`), password, firstName: 'Test', gdprConsent: true });

        expect(response.status).toBe(400);
      });
    });
  });

  describe('Numeric Input Validation', () => {
    const invalidNumbers = ['abc', '1.2.3', 'NaN', 'Infinity', '-Infinity', '1e999', '1n'];

    invalidNumbers.forEach((num, i) => {
      it(`rejects invalid numeric ID #${i + 1}: ${num}`, async () => {
        const response = await request(app.getHttpServer()).get(`/api/menus/${num}`);
        expect([400, 404]).toContain(response.status);
      });
    });

    it('handles hex notation ID', async () => {
      const response = await request(app.getHttpServer()).get('/api/menus/0x1');
      expect([200, 400, 404]).toContain(response.status);
    });

    it('rejects negative ID', async () => {
      const response = await request(app.getHttpServer()).get('/api/menus/-1');
      expect([400, 404]).toContain(response.status);
    });

    it('rejects zero ID', async () => {
      const response = await request(app.getHttpServer()).get('/api/menus/0');
      expect([400, 404]).toContain(response.status);
    });

    it('rejects very large ID', async () => {
      const response = await request(app.getHttpServer()).get('/api/menus/99999999999999999999');
      expect([400, 404, 500]).toContain(response.status);
    });
  });

  describe('String Length Validation', () => {
    it('rejects extremely long firstName', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/register')
        .send({ email: testUtils.uniqueEmail('long'), password: 'Test123!', firstName: 'a'.repeat(10000) });

      expect([400, 500]).toContain(response.status);
    });

    it('rejects empty firstName', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/register')
        .send({ email: testUtils.uniqueEmail('empty'), password: 'Test123!', firstName: '', gdprConsent: true });

      expect(response.status).toBe(400);
    });
  });

  describe('Type Coercion', () => {
    it('rejects array as email', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({ email: ['admin@test.com'], password: 'test' });

      expect(response.status).toBe(400);
    });

    it('rejects object as password', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({ email: 'test@test.com', password: { $ne: '' } });

      expect(response.status).toBe(400);
    });

    it('rejects number as email', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({ email: 12345, password: 'test' });

      expect(response.status).toBe(400);
    });
  });
});
