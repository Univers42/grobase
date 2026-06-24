import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, HttpStatus } from '@nestjs/common';
import * as request from 'supertest';

describe('Delegation E2E', () => {
  let app: INestApplication;
  let authToken: string;

  beforeAll(async () => {
    // In a real setup, we'd create the full app
  });

  afterAll(async () => {
    if (app) await app.close();
  });

  describe('POST /delegation', () => {
    it('should return 401 without auth', async () => {
      await request(app?.getHttpServer?.() || 'http://localhost:3000')
        .post('/delegation')
        .send({
          targetUserId: '60d0fe4f5311236168a109ca',
          permissions: ['manage_playlist'],
          expiresAt: new Date(Date.now() + 86400000).toISOString(),
        })
        .expect(HttpStatus.UNAUTHORIZED);
    });
  });

  describe('GET /delegation', () => {
    it('should return 401 without auth', async () => {
      await request(app?.getHttpServer?.() || 'http://localhost:3000')
        .get('/delegation')
        .expect(HttpStatus.UNAUTHORIZED);
    });
  });

  describe('DELETE /delegation/:id', () => {
    it('should return 401 without auth', async () => {
      await request(app?.getHttpServer?.() || 'http://localhost:3000')
        .delete('/delegation/60d0fe4f5311236168a109ca')
        .expect(HttpStatus.UNAUTHORIZED);
    });
  });

  describe('GET /delegation/devices', () => {
    it('should return 401 without auth', async () => {
      await request(app?.getHttpServer?.() || 'http://localhost:3000')
        .get('/delegation/devices')
        .expect(HttpStatus.UNAUTHORIZED);
    });
  });

  describe('POST /delegation/devices/register', () => {
    it('should return 401 without auth', async () => {
      await request(app?.getHttpServer?.() || 'http://localhost:3000')
        .post('/delegation/devices/register')
        .send({ name: 'Living Room Speaker', type: 'speaker' })
        .expect(HttpStatus.UNAUTHORIZED);
    });
  });
});
