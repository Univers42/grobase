# Security Configuration Guide

This document details all security measures implemented in the Vite Gourmand backend.

## Security Layers

```
┌─────────────────────────────────────────────────────────────┐
│                     SECURITY LAYERS                          │
├─────────────────────────────────────────────────────────────┤
│  1. CA-backed HTTPS    → Encrypted transport, HSTS          │
│  2. Helmet.js          → Security Headers                   │
│  3. CORS               → Cross-Origin Protection            │
│  4. Rate Limiting      → DDoS Protection                    │
│  5. JWT Authentication → Identity Verification              │
│  6. Role-Based Access  → Authorization                      │
│  7. Input Validation   → Data Sanitization                  │
│  8. Password Hashing   → bcrypt (12 rounds)                 │
│  9. Error Masking      → No Internal Data Leakage           │
└─────────────────────────────────────────────────────────────┘
```

## 0. CA-Backed HTTPS Transport

**Location**: `src/main.ts`, `infrastructure/services/fly/config/fly.toml`, `.env.production.example`

Production public traffic must use a browser-trusted CA certificate and `https://` URLs only. Localhost HTTP is allowed only for development and CI.

**Controls**:

- `infrastructure/services/fly/config/fly.toml` keeps `force_https = true`.
- Production enables Express `trust proxy` so `X-Forwarded-Proto` is honored.
- Requests reported as `http` by the proxy receive a permanent `308` redirect to `https`.
- Helmet sends `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload` in production.
- Production public origin env vars are rejected if they use public `http://` values.
- CI fails if HTTPS enforcement, HSTS, or Fly HTTPS forcing is removed.

**Required production variables**:

```properties
NODE_ENV=production
COOKIE_SECURE=true
FRONTEND_URL=https://vite-gourmand.fr
PUBLIC_SITE_URL=https://vite-gourmand.fr
VITE_PUBLIC_SITE_URL=https://vite-gourmand.fr
VITE_API_URL=
```

If `VITE_API_URL` is set for a separate API host, it must also use `https://`.

## 1. Helmet.js - Security Headers

**Location**: `src/main.ts`

```typescript
import helmet from 'helmet';

app.use(helmet());
```

**Headers Applied**:

| Header | Value | Purpose |
|--------|-------|---------|
| `X-Content-Type-Options` | `nosniff` | Prevent MIME sniffing |
| `X-Frame-Options` | `DENY` | Prevent clickjacking |
| `X-XSS-Protection` | `1; mode=block` | XSS filter |
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains; preload` | Force HTTPS |
| `Content-Security-Policy` | (default policy) | Prevent XSS, injection |
| `X-Download-Options` | `noopen` | IE download protection |
| `X-Permitted-Cross-Domain-Policies` | `none` | Flash/PDF protection |
| `Referrer-Policy` | `no-referrer` | Referrer protection |

## 2. CORS Configuration

**Location**: `src/main.ts`

```typescript
app.enableCors({
  origin: getPublicOrigins(),
  credentials: true,
});
```

**Settings**:
- Restricts origins to frontend URL only
- Allows credentials (cookies, auth headers)
- In production, public origins must be CA-backed `https://` URLs

## 3. Rate Limiting (Throttler)

**Location**: `src/app.module.ts`

```typescript
ThrottlerModule.forRoot({
  throttlers: [
    { name: 'short', ttl: 1000, limit: 3 },      // 3 requests per second
    { name: 'medium', ttl: 10000, limit: 20 },   // 20 requests per 10 seconds
    { name: 'long', ttl: 60000, limit: 100 },    // 100 requests per minute
  ],
}),
```

**Response when rate limited**:
```json
{
  "statusCode": 429,
  "message": "ThrottlerException: Too Many Requests"
}
```

**Customizing for specific routes**:
```typescript
import { Throttle, SkipThrottle } from '@nestjs/throttler';

@Throttle({ default: { limit: 1, ttl: 60000 } }) // 1 per minute
@Post('login')
async login() {}

@SkipThrottle() // No rate limiting
@Get('public')
async publicEndpoint() {}
```

## 4. JWT Authentication

**Location**: `src/auth/`, `src/common/guards/`

### Token Structure

```typescript
interface TokenPayload {
  id: number;
  email: string;
  role: string;
  firstName: string;
}
```

### Token Generation

```typescript
// Access token - 15 minutes
const accessToken = this.jwtService.sign(payload, {
  secret: process.env.JWT_SECRET,
  expiresIn: '15m',
});

// Refresh token - 7 days
const refreshToken = this.jwtService.sign(payload, {
  secret: process.env.JWT_REFRESH_SECRET,
  expiresIn: '7d',
});
```

### Token Verification

**Location**: `src/common/guards/jwt-auth.guard.ts`

```typescript
const payload = await this.jwtService.verifyAsync<UserPayload>(token, {
  secret: this.configService.get<string>('JWT_SECRET'),
});
request['user'] = payload;
```

### Environment Variables

```properties
JWT_SECRET=your-super-secret-jwt-key-change-in-production
JWT_REFRESH_SECRET=your-super-secret-refresh-key-change-in-production
```

⚠️ **Important**: Change these in production!

## 5. Role-Based Access Control

**Location**: `src/common/guards/roles.guard.ts`, `src/common/decorators/roles.decorator.ts`

### Define Required Roles

```typescript
@Roles('admin', 'manager')
@Get('admin-only')
async adminEndpoint() {}
```

### Role Guard Implementation

```typescript
@Injectable()
export class RolesGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const requiredRoles = this.reflector.getAllAndOverride<string[]>(
      ROLES_KEY,
      [context.getHandler(), context.getClass()],
    );
    
    if (!requiredRoles) return true;
    
    const { user } = context.switchToHttp().getRequest();
    return requiredRoles.some((role) => user.role === role);
  }
}
```

### Available Roles

| Role | Description |
|------|-------------|
| `admin` | Full system access |
| `manager` | Order and menu management |
| `client` | Order placement and viewing |

## 6. Input Validation

**Location**: `src/common/pipes/validation.pipe.ts`

### Validation Configuration

```typescript
const object = plainToInstance(metatype, value, {
  excludeExtraneousValues: true, // Security: only exposed fields
});

const errors = await validate(object, {
  whitelist: true,           // Strip unknown properties
  forbidNonWhitelisted: true, // Error on unknown properties
  transform: true,           // Auto-transform types
  validationError: {
    target: false,           // Don't expose target object
    value: false,            // Don't expose input value
  },
});
```

### DTO Validation Example

```typescript
export class LoginDto {
  @IsEmail({}, { message: 'Please provide a valid email address' })
  email!: string;

  @IsString()
  @MinLength(8, { message: 'Password must be at least 8 characters' })
  @MaxLength(128, { message: 'Password must not exceed 128 characters' })
  password!: string;
}
```

## 7. Password Security

**Location**: `src/auth/auth.service.ts`

### Hashing

```typescript
import * as bcrypt from 'bcrypt';

const SALT_ROUNDS = 12;
const hashedPassword = await bcrypt.hash(password, SALT_ROUNDS);
```

### Verification

```typescript
const isPasswordValid = await bcrypt.compare(dto.password, user.password);
```

### Password Requirements

- Minimum 8 characters
- Maximum 128 characters
- Stored as bcrypt hash (60 characters)

## 8. Error Masking

**Location**: `src/common/filters/`

### HTTP Exception Filter

Handles known exceptions with appropriate messages:

```typescript
@Catch(HttpException)
export class HttpExceptionFilter implements ExceptionFilter {
  catch(exception: HttpException, host: ArgumentsHost) {
    const status = exception.getStatus();
    const message = exception.message;
    
    response.status(status).json({
      success: false,
      statusCode: status,
      message: message,
      timestamp: new Date().toISOString(),
    });
  }
}
```

### All Exceptions Filter

Catches unhandled exceptions and masks internal details:

```typescript
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  catch(exception: unknown, host: ArgumentsHost) {
    // Log full error internally
    this.logger.error('Unhandled error:', exception);
    
    // Return generic message to client
    response.status(500).json({
      success: false,
      statusCode: 500,
      message: 'Internal server error', // No internal details!
      timestamp: new Date().toISOString(),
    });
  }
}
```

## 9. Public Routes

**Location**: `src/common/decorators/public.decorator.ts`

Routes that don't require authentication:

```typescript
import { Public } from './common/decorators/public.decorator';

@Public()
@Post('login')
async login() {}

@Public()
@Post('register')
async register() {}
```

## 10. Security Headers Checklist

Run the diagnostic to verify:

```bash
./scripts/diagnostic.sh security
```

Expected output:
```
🔒 SECURITY CHECK
==========================================
1️⃣  Security Headers (Helmet)
✅ Helmet.js installed
✅ Helmet configured in main.ts

2️⃣  CORS Configuration
✅ CORS configured

3️⃣  Rate Limiting / Throttling
✅ @nestjs/throttler installed
✅ Throttler configured in AppModule

4️⃣  SQL Injection Protection
✅ Using Prisma ORM (parameterized queries)
✅ No raw SQL queries in application code

5️⃣  XSS Protection
✅ ValidationPipe transform enabled

6️⃣  Sensitive Data in Logs
✅ No password value logging detected

7️⃣  Environment Variables
✅ .env in .gitignore
✅ No hardcoded secrets detected

8️⃣  HTTPS / TLS
✅ Cookie security configured in .env

9️⃣  Dependency Vulnerabilities
ℹ️  Run 'npm audit' in backend for vulnerability scan

🔟 JWT Token Security
✅ JWT expiration configured
✅ Refresh token mechanism found

📊 Summary: 15 passed, 0 failed, 0 warnings
```

## Production Checklist

Before deploying to production:

- [ ] Change `JWT_SECRET` and `JWT_REFRESH_SECRET`
- [ ] Set `NODE_ENV=production`
- [ ] Set `COOKIE_SECURE=true`
- [ ] Configure HTTPS via reverse proxy (nginx, Cloudflare)
- [ ] Set proper `FRONTEND_URL` for CORS
- [ ] Run `npm audit` and fix vulnerabilities
- [ ] Enable database SSL (`sslmode=require`)
- [ ] Review rate limiting settings for your traffic

## Security Headers Test

Use [securityheaders.com](https://securityheaders.com) to test your headers after deployment.

Expected grade: **A** or **A+**
