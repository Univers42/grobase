# Load Testing — Music Room

## Prerequisites

Install [k6](https://k6.io/docs/get-started/installation/):

```bash
# macOS
brew install k6

# Linux (Debian/Ubuntu)
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D68
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install k6
```

## Running Tests

### Standard Load Test
Simulates gradual ramp-up from 10 → 50 → 100 concurrent users:

```bash
# Using default API URL (http://localhost:3000)
k6 run k6-load-test.js

# With custom API URL
k6 run --env API_URL=https://api.music-room.dev k6-load-test.js

# With custom test credentials
k6 run --env TEST_EMAIL=test@test.com --env TEST_PASSWORD=pass123 k6-load-test.js
```

### Spike Test
Simulates sudden traffic burst (5 → 200 users) to test rate limiting and resilience:

```bash
k6 run k6-spike-test.js
```

## Interpreting Results

### Key Metrics
| Metric | Target | Description |
|--------|--------|-------------|
| `http_req_duration p(95)` | < 500ms | 95th percentile response time |
| `http_req_duration p(99)` | < 1000ms | 99th percentile response time |
| `errors` | < 10% | Request failure rate |
| `login_duration p(95)` | < 800ms | Auth endpoint response time |
| `search_duration p(95)` | < 600ms | Music search response time |

### Thresholds
Tests are configured with automatic pass/fail thresholds. If any threshold is exceeded, k6 exits with a non-zero code.

### Performance Targets
- **Throughput**: 100+ requests/second sustained
- **Latency**: p95 < 500ms for read endpoints
- **Error rate**: < 1% under normal load, < 30% during spike (rate limiting)
- **Recovery**: System should recover within 30s after spike

## CI Integration

Add to GitHub Actions:

```yaml
- name: Run k6 load test
  uses: grafana/k6-action@v0.3
  with:
    filename: load-tests/k6-load-test.js
  env:
    API_URL: http://localhost:3000
```

## Architecture Notes

- Rate limiting is configured at 60 req/min per IP by default
- MongoDB indexes (compound + 2dsphere) optimize read queries
- WebSocket connections are tested separately (see integration tests)
- Deezer API proxy has its own rate limits from upstream
