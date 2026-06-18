/**
 * Jest E2E Test Setup
 * This file runs before each test file.
 */

process.env.NODE_ENV = 'test';
jest.setTimeout(30000);

// Ensure clean exit after tests
afterAll(async () => {
  await new Promise((resolve) => setTimeout(resolve, 100));
});
