import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import * as request from 'supertest';
import { AppModule } from '../src/app.module';

describe('User Endpoints (e2e)', () => {
  let app: INestApplication;
  let accessToken: string;
  let userId: string;

  beforeAll(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();

    app = moduleFixture.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }),
    );
    await app.init();

    const res = await request(app.getHttpServer())
      .post('/auth/register')
      .send({
        email: `user-e2e-${Date.now()}@test.com`,
        password: 'TestPass123!',
        username: `user_e2e_${Date.now()}`,
      });
    accessToken = res.body.accessToken;
    userId = res.body.user?._id;
  });

  afterAll(async () => {
    await app.close();
  });

  describe('GET /users/profile', () => {
    it('should get own profile', () => {
      return request(app.getHttpServer())
        .get('/users/profile')
        .set('Authorization', `Bearer ${accessToken}`)
        .expect(200)
        .expect((res) => {
          expect(res.body).toHaveProperty('email');
          expect(res.body).toHaveProperty('username');
        });
    });

    it('should reject without auth', () => {
      return request(app.getHttpServer())
        .get('/users/profile')
        .expect(401);
    });
  });

  describe('PATCH /users/profile', () => {
    it('should update profile', () => {
      return request(app.getHttpServer())
        .patch('/users/profile')
        .set('Authorization', `Bearer ${accessToken}`)
        .send({ displayName: 'E2E User' })
        .expect(200)
        .expect((res) => {
          expect(res.body.displayName).toBe('E2E User');
        });
    });
  });

  describe('GET /users/search', () => {
    it('should search users by username', () => {
      return request(app.getHttpServer())
        .get('/users/search?q=user_e2e')
        .set('Authorization', `Bearer ${accessToken}`)
        .expect(200)
        .expect((res) => {
          expect(Array.isArray(res.body)).toBe(true);
        });
    });
  });

  describe('PATCH /users/privacy', () => {
    it('should update privacy settings', () => {
      return request(app.getHttpServer())
        .patch('/users/privacy')
        .set('Authorization', `Bearer ${accessToken}`)
        .send({ level: 'friends' })
        .expect(200);
    });
  });
});
