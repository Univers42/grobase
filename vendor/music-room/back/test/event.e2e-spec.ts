import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import * as request from 'supertest';
import { AppModule } from '../src/app.module';

describe('Event Endpoints (e2e)', () => {
  let app: INestApplication;
  let accessToken: string;
  let eventId: string;

  beforeAll(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();

    app = moduleFixture.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }),
    );
    await app.init();

    // Register and get token
    const res = await request(app.getHttpServer())
      .post('/auth/register')
      .send({
        email: `event-e2e-${Date.now()}@test.com`,
        password: 'TestPass123!',
        username: `event_e2e_${Date.now()}`,
      });
    accessToken = res.body.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  describe('POST /events', () => {
    it('should create an event', () => {
      return request(app.getHttpServer())
        .post('/events')
        .set('Authorization', `Bearer ${accessToken}`)
        .send({
          name: 'E2E Test Event',
          description: 'Integration test event',
          location: { type: 'Point', coordinates: [2.3522, 48.8566] },
          timeWindow: {
            start: new Date(Date.now() + 86400000).toISOString(),
            end: new Date(Date.now() + 172800000).toISOString(),
          },
          visibility: 'public',
          tags: ['test', 'e2e'],
        })
        .expect(201)
        .expect((res) => {
          expect(res.body).toHaveProperty('_id');
          expect(res.body.name).toBe('E2E Test Event');
          eventId = res.body._id;
        });
    });

    it('should reject event without name', () => {
      return request(app.getHttpServer())
        .post('/events')
        .set('Authorization', `Bearer ${accessToken}`)
        .send({
          description: 'Missing name',
          location: { type: 'Point', coordinates: [0, 0] },
        })
        .expect(400);
    });
  });

  describe('GET /events', () => {
    it('should list events', () => {
      return request(app.getHttpServer())
        .get('/events')
        .set('Authorization', `Bearer ${accessToken}`)
        .expect(200)
        .expect((res) => {
          expect(Array.isArray(res.body)).toBe(true);
        });
    });
  });

  describe('GET /events/:id', () => {
    it('should get event details', () => {
      return request(app.getHttpServer())
        .get(`/events/${eventId}`)
        .set('Authorization', `Bearer ${accessToken}`)
        .expect(200)
        .expect((res) => {
          expect(res.body._id).toBe(eventId);
        });
    });

    it('should return 400 for invalid ObjectId', () => {
      return request(app.getHttpServer())
        .get('/events/invalid-id')
        .set('Authorization', `Bearer ${accessToken}`)
        .expect(400);
    });
  });
});
