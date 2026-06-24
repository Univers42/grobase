# Security Architecture — Music Room

## Overview

This document describes the security measures implemented across the Music Room platform.

## Authentication

### JWT Token System
- **Access tokens**: Short-lived (15 min default), signed with HS256
- **Refresh tokens**: Long-lived (7 days), single-use rotation
- **Theft detection**: When a refresh token is reused, all sessions for the user are invalidated
- **Secure storage**: Tokens stored in `expo-secure-store` (iOS Keychain / Android Keystore), with memory-only fallback for web

### Password Security
- Passwords hashed with **bcrypt** (12 salt rounds)
- Minimum 8 characters enforced via `class-validator`
- Password reset via time-limited email tokens (1 hour expiry)

### OAuth 2.0
- Google Sign-In (ID token verification)
- Facebook Login (access token exchange)
- Account linking for social + email accounts

## API Security

### Rate Limiting
- Global: 60 requests per minute per IP (configurable via `THROTTLE_TTL` / `THROTTLE_LIMIT`)
- Auth endpoints: Stricter limits (5/min for login, 3/min for register)
- Implemented via `@nestjs/throttler` with `ThrottlerGuard`

### Input Validation
- **class-validator** DTOs with `whitelist: true` and `forbidNonWhitelisted: true`
- All request bodies are validated and transformed before reaching controllers
- Unknown properties are stripped automatically

### Input Sanitization
- **SanitizeMiddleware** applied globally:
  - Strips MongoDB operators (`$gt`, `$ne`, `$regex`, etc.) — prevents NoSQL injection
  - Removes HTML tags — prevents stored XSS
  - Blocks prototype pollution (`__proto__`, `constructor`, `prototype`)

### HTTP Headers
- **Helmet.js** with strict configuration:
  - **Content-Security-Policy**: Restrictive directives, only allows Deezer CDN for images
  - **HSTS**: 1-year max-age with preload
  - **X-Content-Type-Options**: nosniff
  - **X-Frame-Options**: DENY
  - **Referrer-Policy**: strict-origin-when-cross-origin

### CORS
- Origin allowlist via `CORS_ORIGINS` env variable
- Credentials enabled
- Restricted methods: GET, POST, PATCH, DELETE, OPTIONS
- Custom headers whitelisted: Authorization, X-Platform, X-Device-Model, X-App-Version
- Preflight cached for 24 hours

## Data Security

### MongoDB Security
- Connection via URI with authentication
- Mongoose strict mode — rejects fields not in schema
- TTL indexes for automatic data cleanup (logs: 90 days)
- No raw query building — all queries use Mongoose methods

### Authorization
- JWT guard applied globally via `APP_GUARD`
- `@Public()` decorator for explicitly public endpoints
- Resource ownership checks in service layer
- Friend-based privacy (public / friends-only / private profile sections)
- Event license enforcement (open / invited-only / geo-time)

### Subscription Enforcement
- Feature limits checked server-side before actions
- Free tier: limited playlists, events, and track counts
- Premium features: private events, geo-time restrictions, offline mode

## Logging & Monitoring

### Request Logging
- All requests logged with response time, status code, user agent
- Platform analytics (iOS/Android/Web breakdown)
- Error tracking with detailed error messages
- Slow endpoint detection (aggregation pipeline)
- 90-day TTL with automatic cleanup

### Audit Trail
- Playlist operations logged with OT versioning
- Event vote changes tracked with user attribution

## Transport Security

### HTTPS
- HSTS preload headers enforce HTTPS
- In production: TLS 1.2+ required

### WebSocket Security
- Socket.IO with auth token verification on connection
- Room-based access control for events and playlists
- Namespace isolation: `/vote`, `/playlist`

## IoT Security

### MQTT
- Optional MQTT with username/password authentication
- Topic-based access control (per-user namespaces)
- All messages JSON-serialized and validated

## Dependency Security

- Regular `npm audit` for vulnerability scanning
- `class-validator` + `class-transformer` for type-safe DTOs
- No use of `eval()`, `Function()`, or dynamic code execution
