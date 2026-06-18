import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import * as request from 'supertest';
import { AppModule } from '../src/app.module';

describe('Playlist Endpoints (e2e)', () => {
  let app: INestApplication;
  let accessToken: string;
  let playlistId: string;

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
        email: `playlist-e2e-${Date.now()}@test.com`,
        password: 'TestPass123!',
        username: `playlist_e2e_${Date.now()}`,
      });
    accessToken = res.body.accessToken;
  });

  afterAll(async () => {
    await app.close();
  });

  describe('POST /playlists', () => {
    it('should create a playlist', () => {
      return request(app.getHttpServer())
        .post('/playlists')
        .set('Authorization', `Bearer ${accessToken}`)
        .send({
          name: 'E2E Test Playlist',
          description: 'Integration test playlist',
          visibility: 'public',
          genre: 'rock',
        })
        .expect(201)
        .expect((res) => {
          expect(res.body).toHaveProperty('_id');
          expect(res.body.name).toBe('E2E Test Playlist');
          playlistId = res.body._id;
        });
    });

    it('should reject playlist without name', () => {
      return request(app.getHttpServer())
        .post('/playlists')
        .set('Authorization', `Bearer ${accessToken}`)
        .send({ description: 'Missing name' })
        .expect(400);
    });
  });

  describe('GET /playlists', () => {
    it('should list playlists', () => {
      return request(app.getHttpServer())
        .get('/playlists')
        .set('Authorization', `Bearer ${accessToken}`)
        .expect(200)
        .expect((res) => {
          expect(Array.isArray(res.body)).toBe(true);
        });
    });
  });

  describe('GET /playlists/:id', () => {
    it('should get playlist details', () => {
      return request(app.getHttpServer())
        .get(`/playlists/${playlistId}`)
        .set('Authorization', `Bearer ${accessToken}`)
        .expect(200)
        .expect((res) => {
          expect(res.body._id).toBe(playlistId);
          expect(res.body.tracks).toEqual([]);
        });
    });
  });

  describe('POST /playlists/:id/tracks', () => {
    it('should add a track to playlist', () => {
      return request(app.getHttpServer())
        .post(`/playlists/${playlistId}/tracks`)
        .set('Authorization', `Bearer ${accessToken}`)
        .send({
          trackId: '3135556',
          title: 'Harder Better Faster Stronger',
          artist: 'Daft Punk',
          baseVersion: 0,
        })
        .expect(201);
    });
  });
});
