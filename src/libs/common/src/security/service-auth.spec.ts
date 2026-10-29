import { afterEach, describe, expect, it } from '@jest/globals';
import { computeServiceAuth, serviceAuthHeaders } from './service-auth';

// Same vectors as shared/token_test.go and data-plane-pool service_auth.rs: the
// query-router signs what the Rust data plane verifies, byte for byte.
describe('service-auth golden vectors', () => {
  it('signs a POST with a body like Go and Rust', () => {
    expect(
      computeServiceAuth('test-token', 'POST', '/v1/keys/verify', '{"key":"abc"}', 1700000000),
    ).toBe('v1.1700000000.b2e684210cc7e80998388c89afe88d2fbd4fd9a7492289724f7fd3f15075189e');
  });

  it('signs a bodyless GET like Go and Rust', () => {
    expect(computeServiceAuth('test-token', 'get', '/databases/db1/connect', '', 1700000000)).toBe(
      'v1.1700000000.d53d261c30ba227cb3ab770a0a3c936e0fc0cd7385855339ba60b1a172b21b6b',
    );
  });
});

describe('serviceAuthHeaders', () => {
  const saved = process.env.SERVICE_TOKEN_MODE;
  afterEach(() => {
    if (saved === undefined) delete process.env.SERVICE_TOKEN_MODE;
    else process.env.SERVICE_TOKEN_MODE = saved;
  });

  it('sends the plain token outside hmac mode', () => {
    delete process.env.SERVICE_TOKEN_MODE;
    expect(serviceAuthHeaders('tok', 'POST', '/v1/query', '{}')).toEqual({
      'X-Service-Token': 'tok',
    });
  });

  it('never sends the token in hmac mode', () => {
    process.env.SERVICE_TOKEN_MODE = 'HMAC';
    const headers = serviceAuthHeaders('tok', 'POST', '/v1/query', '{}');
    expect(Object.keys(headers)).toEqual(['X-Service-Auth']);
    expect(headers['X-Service-Auth']).toMatch(/^v1\.\d+\.[0-9a-f]{64}$/);
  });
});
