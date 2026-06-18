import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import * as request from 'supertest';
import { AppModule } from '../src/app.module';

describe('Health Endpoints (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();

    app = moduleFixture.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, transform: true }),
    );
    await app.init();
  });

  afterAll(async () => {
    await app.close();
  });

  describe('GET /health', () => {
    it('should return health status', () => {
      return request(app.getHttpServer())
        .get('/health')
        .expect(200)
        .expect((res) => {
          expect(res.body).toHaveProperty('status');
          expect(res.body).toHaveProperty('timestamp');
          expect(res.body).toHaveProperty('uptime');
          expect(res.body).toHaveProperty('services');
          expect(res.body).toHaveProperty('memory');
        });
    });
  });

  describe('GET /health/live', () => {
    it('should return alive status', () => {
      return request(app.getHttpServer())
        .get('/health/live')
        .expect(200)
        .expect({ status: 'alive' });
    });
  });

  describe('GET /health/ready', () => {
    it('should return ready when database connected', () => {
      return request(app.getHttpServer())
        .get('/health/ready')
        .expect(200)
        .expect({ status: 'ready' });
    });
  });
});
