import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const loginDuration = new Trend('login_duration');
const searchDuration = new Trend('search_duration');
const eventListDuration = new Trend('event_list_duration');

// Configuration
const BASE_URL = __ENV.API_URL || 'http://localhost:3000';
const TEST_EMAIL = __ENV.TEST_EMAIL || 'loadtest@example.com';
const TEST_PASSWORD = __ENV.TEST_PASSWORD || 'LoadTest123!';

export const options = {
  stages: [
    { duration: '30s', target: 10 },   // Ramp up to 10 users
    { duration: '1m', target: 50 },     // Ramp up to 50 users
    { duration: '2m', target: 50 },     // Stay at 50 users
    { duration: '1m', target: 100 },    // Ramp up to 100 users
    { duration: '2m', target: 100 },    // Stay at 100 users
    { duration: '30s', target: 0 },     // Ramp down
  ],
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],  // 95% < 500ms, 99% < 1s
    errors: ['rate<0.1'],                              // Error rate < 10%
    login_duration: ['p(95)<800'],
    search_duration: ['p(95)<600'],
    event_list_duration: ['p(95)<400'],
  },
};

// Setup: register test user and get token
export function setup() {
  // Try to register
  http.post(`${BASE_URL}/auth/register`, JSON.stringify({
    email: TEST_EMAIL,
    password: TEST_PASSWORD,
    displayName: 'Load Test User',
  }), { headers: { 'Content-Type': 'application/json' } });

  // Login to get token
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

  // ─── Auth Flow ──────────────────────────
  group('Auth', () => {
    const start = Date.now();
    const loginRes = http.post(`${BASE_URL}/auth/login`, JSON.stringify({
      email: TEST_EMAIL,
      password: TEST_PASSWORD,
    }), { headers: { 'Content-Type': 'application/json' } });

    loginDuration.add(Date.now() - start);

    const success = check(loginRes, {
      'login status 200|201': (r) => r.status === 200 || r.status === 201,
      'login has token': (r) => {
        try { return !!JSON.parse(r.body as string).accessToken; } catch { return false; }
      },
    });
    errorRate.add(!success);
  });

  sleep(1);

  // ─── Music Search ───────────────────────
  group('Music Search', () => {
    const queries = ['rock', 'jazz', 'pop', 'electronic', 'classical'];
    const q = queries[Math.floor(Math.random() * queries.length)];

    const start = Date.now();
    const searchRes = http.get(`${BASE_URL}/music/search?q=${q}`, { headers });
    searchDuration.add(Date.now() - start);

    const success = check(searchRes, {
      'search status 200': (r) => r.status === 200,
      'search has data': (r) => {
        try { return Array.isArray(JSON.parse(r.body as string).data); } catch { return false; }
      },
    });
    errorRate.add(!success);
  });

  sleep(0.5);

  // ─── Events ──────────────────────────────
  group('Events', () => {
    const start = Date.now();
    const eventsRes = http.get(`${BASE_URL}/events`, { headers });
    eventListDuration.add(Date.now() - start);

    const success = check(eventsRes, {
      'events status 200': (r) => r.status === 200,
    });
    errorRate.add(!success);
  });

  sleep(0.5);

  // ─── Playlists ───────────────────────────
  group('Playlists', () => {
    const playlistsRes = http.get(`${BASE_URL}/playlists`, { headers });

    check(playlistsRes, {
      'playlists status 200': (r) => r.status === 200,
    });
  });

  sleep(0.5);

  // ─── Profile ──────────────────────────────
  group('Profile', () => {
    const meRes = http.get(`${BASE_URL}/users/me`, { headers });

    check(meRes, {
      'profile status 200': (r) => r.status === 200,
      'profile has email': (r) => {
        try { return !!JSON.parse(r.body as string).email; } catch { return false; }
      },
    });
  });

  sleep(1);

  // ─── Subscription ────────────────────────
  group('Subscription', () => {
    const subRes = http.get(`${BASE_URL}/subscriptions/me`, { headers });

    check(subRes, {
      'subscription status 200': (r) => r.status === 200,
    });
  });

  sleep(0.5);
}

// Teardown (optional cleanup)
export function teardown(data: { token: string }) {
  // Could delete test user here if needed
}
