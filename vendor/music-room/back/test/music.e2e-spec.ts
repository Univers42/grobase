import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import * as request from 'supertest';
import { AppModule } from '../src/app.module';

describe('Music Endpoints (e2e)', () => {
  let app: INestApplication;
  let accessToken: string;

  beforeAll(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();

    app = moduleFixture.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, transform: true }),
    );
    await app.init();

    // Register and get token
    const res = await request(app.getHttpServer())
      .post('/auth/register')
      .send({
        email: `music-e2e-${Date.now()}@test.com`,
        password: 'TestPass123!',
        username: `music_e2e_${Date.now()}`,
      });
    accessToken = res.body.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  describe('GET /music/search', () => {
    it('should search tracks by query', () => {
      return request(app.getHttpServer())
        .get('/music/search?q=daft+punk')
        .set('Authorization', `Bearer ${accessToken}`)
        .expect(200)
        .expect((res) => {
          expect(res.body).toHaveProperty('data');
          expect(Array.isArray(res.body.data)).toBe(true);
        });
    });

    it('should reject empty query', () => {
      return request(app.getHttpServer())
        .get('/music/search?q=')
        .set('Authorization', `Bearer ${accessToken}`)
        .expect(400);
    });

    it('should require authentication', () => {
      return request(app.getHttpServer())
        .get('/music/search?q=test')
        .expect(401);
    });
  });

  describe('GET /music/track/:id', () => {
    it('should get track details', () => {
      return request(app.getHttpServer())
        .get('/music/track/3135556')
        .set('Authorization', `Bearer ${accessToken}`)
        .expect(200)
        .expect((res) => {
          expect(res.body).toHaveProperty('id');
          expect(res.body).toHaveProperty('title');
        });
    });

    it('should return 404 for invalid track', () => {
      return request(app.getHttpServer())
        .get('/music/track/0')
        .set('Authorization', `Bearer ${accessToken}`)
        .expect(404);
    });
  });
});
