# Testing Guide

This document explains how to run tests and understand test output in the Vite Gourmand project.

## Quick Start

```bash
# Run all tests
cd backend && npm test

# Run tests with coverage
npm run test:cov

# Run tests in watch mode
npm run test:watch

# Run E2E tests
npm run test:e2e
```

## Test Structure

```
backend/
├── src/
│   ├── app.controller.spec.ts          # App controller tests
│   └── common/
│       ├── filters/filters.spec.ts     # Exception filter tests
│       ├── guards/guards.spec.ts       # Guard tests
│       └── pipes/validation.pipe.spec.ts # Validation pipe tests
└── test/
    ├── jest-e2e.json                   # E2E Jest config
    ├── app.e2e-spec.ts                 # App E2E tests
    ├── auth.e2e-spec.ts                # Auth E2E tests
    ├── error-handling.e2e-spec.ts      # Error handling E2E tests
    ├── response.e2e-spec.ts            # Response format E2E tests
    └── validation.e2e-spec.ts          # Validation E2E tests
```

## Understanding Test Output

### Successful Test Run

```
PASS src/common/filters/filters.spec.ts
PASS src/app.controller.spec.ts
PASS src/common/guards/guards.spec.ts
PASS src/common/pipes/validation.pipe.spec.ts

Test Suites: 4 passed, 4 total
Tests:       19 passed, 19 total
Snapshots:   0 total
Time:        0.961 s
```

### Expected Error/Warning Messages

When you run tests, you may see messages like:

```
[Nest] ERROR [AllExceptionsFilter] HTTP 500 - GET /test - Internal server error
[Nest] ERROR [AllExceptionsFilter] HTTP 404 - GET /test - Not found
[Nest] WARN [HttpExceptionFilter] HTTP 400 - GET /test - "Test error"
```

**These are NOT failures!** These are:
- Expected output from tests that verify error handling works correctly
- The tests intentionally trigger errors to verify filters catch them
- If the test passes (`PASS`), the error handling is working correctly

## Test Categories

### 1. Unit Tests (`*.spec.ts` in `src/`)

Test individual components in isolation.

#### App Controller Tests
```typescript
describe('AppController', () => {
  it('should return "Hello World!"', () => {
    expect(appController.getHello()).toBe('Hello World!');
  });
});
```

#### Guard Tests
```typescript
describe('JwtAuthGuard', () => {
  it('should allow access with @Public() decorator', async () => {
    reflector.getAllAndOverride.mockReturnValue(true);
    const result = await guard.canActivate(mockContext);
    expect(result).toBe(true);
  });
});
```

#### Filter Tests
```typescript
describe('HttpExceptionFilter', () => {
  it('should handle BadRequestException', () => {
    const exception = new BadRequestException('Test error');
    filter.catch(exception, mockHost);
    expect(mockResponse.status).toHaveBeenCalledWith(400);
  });
});
```

#### Validation Pipe Tests
```typescript
describe('CustomValidationPipe', () => {
  it('should pass valid data', async () => {
    const result = await pipe.transform(validDto, metadata);
    expect(result.email).toBe('test@example.com');
  });

  it('should throw BadRequestException for invalid email', async () => {
    await expect(
      pipe.transform({ email: 'invalid' }, metadata)
    ).rejects.toThrow(BadRequestException);
  });
});
```

### 2. E2E Tests (`*.e2e-spec.ts` in `test/`)

Test the full application stack.

```typescript
describe('AuthController (e2e)', () => {
  it('/auth/login (POST)', () => {
    return request(app.getHttpServer())
      .post('/auth/login')
      .send({ email: 'test@example.com', password: 'password123' })
      .expect(200)
      .expect((res) => {
        expect(res.body.accessToken).toBeDefined();
      });
  });
});
```

## Running Specific Tests

```bash
# Run a single test file
npm test -- src/common/guards/guards.spec.ts

# Run tests matching a pattern
npm test -- --testNamePattern="JwtAuthGuard"

# Run tests with verbose output
npm test -- --verbose

# Run tests and show coverage
npm run test:cov
```

## Test Coverage

Run coverage report:
```bash
npm run test:cov
```

Coverage report is generated in `backend/coverage/` directory.

Open `coverage/lcov-report/index.html` in a browser to view the detailed report.

## Writing New Tests

### 1. Create Test File

Create `*.spec.ts` next to the file you're testing:

```
src/
├── my-service.ts
└── my-service.spec.ts
```

### 2. Basic Test Structure

```typescript
import { Test, TestingModule } from '@nestjs/testing';
import { MyService } from './my-service';

describe('MyService', () => {
  let service: MyService;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [MyService],
    }).compile();

    service = module.get<MyService>(MyService);
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  describe('myMethod', () => {
    it('should return expected value', () => {
      const result = service.myMethod('input');
      expect(result).toBe('expected output');
    });

    it('should throw error for invalid input', () => {
      expect(() => service.myMethod(null)).toThrow();
    });
  });
});
```

### 3. Mocking Dependencies

```typescript
const mockPrismaService = {
  user: {
    findUnique: jest.fn(),
    create: jest.fn(),
  },
};

const module: TestingModule = await Test.createTestingModule({
  providers: [
    MyService,
    { provide: PrismaService, useValue: mockPrismaService },
  ],
}).compile();
```

## Diagnostic Tests

The project also includes diagnostic checks via shell scripts:

```bash
# Run diagnostic test suite
./scripts/diagnostic.sh tests
```

This runs the Jest tests and reports results in the diagnostic format.

## CI/CD Integration

For CI/CD pipelines, use:

```bash
# Run tests with JUnit reporter
npm test -- --ci --reporters=default --reporters=jest-junit

# Run tests with coverage threshold
npm run test:cov -- --coverageThreshold='{"global":{"branches":80,"functions":80,"lines":80}}'
```

## Troubleshooting

### Tests timing out

Increase Jest timeout in `jest.config.js`:
```javascript
module.exports = {
  testTimeout: 30000, // 30 seconds
};
```

### Module not found errors

Ensure `tsconfig.json` paths are configured:
```json
{
  "compilerOptions": {
    "baseUrl": "./",
    "paths": {
      "@/*": ["src/*"]
    }
  }
}
```

### Database connection errors in tests

Tests should use mocks, not real database:
```typescript
const mockPrismaService = {
  user: { findUnique: jest.fn() },
};
```

For E2E tests with real database:
```bash
# Set test database
DATABASE_URL=postgresql://...test_db npm run test:e2e
```
