import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('errors');
const BASE_URL = __ENV.API_URL || 'http://localhost:3000';
const TEST_EMAIL = __ENV.TEST_EMAIL || 'spiketest@example.com';
const TEST_PASSWORD = __ENV.TEST_PASSWORD || 'SpikeTest123!';

/**
 * Spike test — simulates sudden traffic bursts to test system resilience.
 * Useful for testing rate limiting, auto-scaling, and error handling under load.
 */
export const options = {
  stages: [
    { duration: '10s', target: 5 },     // Warm up
    { duration: '10s', target: 200 },    // Spike!
    { duration: '30s', target: 200 },    // Hold spike
    { duration: '10s', target: 5 },      // Scale down
    { duration: '30s', target: 5 },      // Recovery period
    { duration: '10s', target: 0 },      // Ramp down
  ],
  thresholds: {
    http_req_duration: ['p(99)<2000'],   // 99% < 2s even during spike
    errors: ['rate<0.3'],                 // Allow up to 30% errors during spike (rate limiting)
  },
};

export function setup() {
  http.post(`${BASE_URL}/auth/register`, JSON.stringify({
    email: TEST_EMAIL,
    password: TEST_PASSWORD,
    displayName: 'Spike Test User',
  }), { headers: { 'Content-Type': 'application/json' } });

  const loginRes = http.post(`${BASE_URL}/auth/login`, JSON.stringify({
    email: TEST_EMAIL,
    password: TEST_PASSWORD,
  }), { headers: { 'Content-Type': 'application/json' } });

  const body = JSON.parse(loginRes.body as string);
  return { token: body.accessToken };
}

export default function (data: { token: string }) {
  const headers = {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${data.token}`,
  };

  // Mix of endpoints to simulate real usage
  const endpoints = [
    { method: 'GET', url: `${BASE_URL}/users/me` },
    { method: 'GET', url: `${BASE_URL}/events` },
    { method: 'GET', url: `${BASE_URL}/playlists` },
    { method: 'GET', url: `${BASE_URL}/music/search?q=test` },
    { method: 'GET', url: `${BASE_URL}/subscriptions/me` },
  ];

  const endpoint = endpoints[Math.floor(Math.random() * endpoints.length)];
  const res = http.get(endpoint.url, { headers });

  const success = check(res, {
    'status is 200 or 429': (r) => r.status === 200 || r.status === 429,
  });

  errorRate.add(!success);
  sleep(0.1);
}
