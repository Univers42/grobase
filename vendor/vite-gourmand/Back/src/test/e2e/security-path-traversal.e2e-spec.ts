/**
 * Path Traversal Prevention E2E Tests
 */
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../test-utils';

describe('Path Traversal Prevention (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  const traversalPayloads = [
    '../etc/passwd',
    '..\\..\\..\\windows\\system32\\config\\sam',
    '....//....//etc/passwd',
    '..%2f..%2f..%2fetc/passwd',
    '..%252f..%252f..%252fetc/passwd',
    '%2e%2e%2f%2e%2e%2f',
    '..%c0%af..%c0%af',
    '..%00/etc/passwd',
    '....\\....\\etc\\passwd',
    '/etc/passwd%00.png',
  ];

  describe('Menu ID Path Traversal', () => {
    traversalPayloads.forEach((payload, i) => {
      it(`blocks path traversal #${i + 1}`, async () => {
        const response = await request(app.getHttpServer()).get(
          `/api/menus/${encodeURIComponent(payload)}`,
        );

        expect([400, 404]).toContain(response.status);
        expect(response.text).not.toContain('root:');
      });
    });
  });

  describe('Dish ID Path Traversal', () => {
    traversalPayloads.slice(0, 5).forEach((payload, i) => {
      it(`blocks path traversal #${i + 1}`, async () => {
        const response = await request(app.getHttpServer()).get(
          `/api/dishes/${encodeURIComponent(payload)}`,
        );

        expect([400, 404]).toContain(response.status);
      });
    });
  });

  describe('Query Parameter Path Traversal', () => {
    traversalPayloads.slice(0, 5).forEach((payload, i) => {
      it(`blocks path traversal in search #${i + 1}`, async () => {
        const response = await request(app.getHttpServer()).get(
          `/api/menus?search=${encodeURIComponent(payload)}`,
        );

        expect([200, 400]).toContain(response.status);
        expect(response.text).not.toContain('root:');
      });
    });
  });
});
