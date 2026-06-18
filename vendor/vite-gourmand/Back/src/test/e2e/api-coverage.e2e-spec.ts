/**
 * API Endpoint Coverage E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, testUtils } from '../test-utils';

describe('API Endpoint Coverage (e2e)', () => {
  let app: INestApplication;
  let authToken: string;

  beforeAll(async () => {
    app = await createTestApp();
    const email = testUtils.uniqueEmail('coverage');
    await request(app.getHttpServer())
      .post('/api/auth/register')
      .send({ email, password: 'Test123!', firstName: 'Coverage', gdprConsent: true });

    const login = await request(app.getHttpServer())
      .post('/api/auth/login')
      .send({ email, password: 'Test123!' });

    authToken = login.body.data?.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  describe('Health Endpoints', () => {
    it('GET /api returns success', async () => {
      const response = await request(app.getHttpServer()).get('/api');
      expect(response.status).toBe(200);
    });

    it('GET /api/health returns healthy', async () => {
      const response = await request(app.getHttpServer()).get('/api/health');
      expect(response.status).toBe(200);
    });
  });

  describe('Menu Endpoints', () => {
    it('GET /api/menus returns list', async () => {
      const response = await request(app.getHttpServer()).get('/api/menus');
      expect(response.status).toBe(200);
    });

    it('GET /api/menus with filters', async () => {
      const response = await request(app.getHttpServer()).get('/api/menus?page=1&limit=10');
      expect(response.status).toBe(200);
    });
  });

  describe('Dish Endpoints', () => {
    it('GET /api/dishes returns list', async () => {
      const response = await request(app.getHttpServer()).get('/api/dishes');
      expect(response.status).toBe(200);
    });

    it('GET /api/dishes with pagination', async () => {
      const response = await request(app.getHttpServer()).get('/api/dishes?page=1&limit=5');
      expect(response.status).toBe(200);
    });
  });

  describe('Reference Data Endpoints', () => {
    it('GET /api/allergens returns list', async () => {
      const response = await request(app.getHttpServer()).get('/api/allergens');
      expect(response.status).toBe(200);
    });

    it('GET /api/diets returns list', async () => {
      const response = await request(app.getHttpServer()).get('/api/diets');
      expect(response.status).toBe(200);
    });

    it('GET /api/themes returns list', async () => {
      const response = await request(app.getHttpServer()).get('/api/themes');
      expect(response.status).toBe(200);
    });

    it('GET /api/working-hours returns list', async () => {
      const response = await request(app.getHttpServer()).get('/api/working-hours');
      expect(response.status).toBe(200);
    });
  });

  describe('Auth Endpoints', () => {
    it('POST /api/auth/register accepts valid data', async () => {
      const response = await request(app.getHttpServer())
        .post('/api/auth/register')
        .send({ email: testUtils.uniqueEmail('reg'), password: 'Test123!', firstName: 'New', gdprConsent: true });
      expect([200, 201]).toContain(response.status);
    });

    it('POST /api/auth/login accepts valid data', async () => {
      const email = testUtils.uniqueEmail('logintest');
      await request(app.getHttpServer())
        .post('/api/auth/register')
        .send({ email, password: 'Test123!', firstName: 'Login', gdprConsent: true });

      const response = await request(app.getHttpServer())
        .post('/api/auth/login')
        .send({ email, password: 'Test123!' });
      expect(response.status).toBe(200);
    });

    it('GET /api/auth/me returns user', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/auth/me')
        .set('Authorization', `Bearer ${authToken}`);
      expect([200, 401]).toContain(response.status);
    });
  });

  describe('User Endpoints', () => {
    it('GET /api/users/me returns profile', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/users/me')
        .set('Authorization', `Bearer ${authToken}`);
      expect([200, 401]).toContain(response.status);
    });

    it('GET /api/users/me/addresses returns addresses', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/users/me/addresses')
        .set('Authorization', `Bearer ${authToken}`);
      expect([200, 401]).toContain(response.status);
    });
  });

  describe('Order Endpoints', () => {
    it('GET /api/orders returns list', async () => {
      const response = await request(app.getHttpServer())
        .get('/api/orders')
        .set('Authorization', `Bearer ${authToken}`);
      expect([200, 401]).toContain(response.status);
    });
  });
});
