# Architecture Overview

This document describes the technical architecture of Music Room.

## System Architecture

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│  Mobile App  │────▶│  NestJS API  │────▶│   MongoDB    │
│  (Expo RN)   │◀────│  (REST + WS) │◀────│  (Document)  │
└─────────────┘     └──────┬───────┘     └──────────────┘
                           │
                    ┌──────┴───────┐
                    │  Deezer API  │
                    │  (External)  │
                    └──────────────┘
```

## Design Principles

### Modular Monolith

The backend is structured as a **modular monolith** — a single deployable unit with clear module boundaries. Each feature module is self-contained with its own:

- Schema (Mongoose model)
- DTOs (validation)
- Service (business logic)
- Controller (HTTP endpoints)
- Gateway (WebSocket, where applicable)

This provides the organizational benefits of microservices without the operational complexity.

### Module Dependency Graph

```
AppModule
├── AuthModule (core, no imports)
├── UserModule → AuthModule
├── MusicModule (standalone, calls Deezer API)
├── EventModule → AuthModule
├── PlaylistModule → AuthModule
├── DelegationModule → AuthModule
├── LoggingModule (global interceptor)
├── SubscriptionModule → AuthModule
└── IoTModule (optional MQTT)
```

## Backend Architecture

### Request Flow

```
HTTP Request
  │
  ▼
Helmet (CSP, HSTS)    ──▶ Security headers
  │
  ▼
CORS Middleware        ──▶ Origin validation
  │
  ▼
SanitizeMiddleware     ──▶ NoSQL injection, XSS, proto pollution
  │
  ▼
ThrottlerGuard         ──▶ Rate limiting
  │
  ▼
JwtAuthGuard           ──▶ Authentication (bypassed for @Public)
  │
  ▼
ValidationPipe         ──▶ DTO validation (whitelist + transform)
  │
  ▼
Controller             ──▶ Route handling
  │
  ▼
Service                ──▶ Business logic
  │
  ▼
Mongoose Model         ──▶ Database operations
  │
  ▼
LoggingInterceptor     ──▶ Fire-and-forget request logging
  │
  ▼
HTTP Response
```

### Authentication

- **JWT** with access + refresh token pattern
- **Refresh Token Rotation**: each refresh generates new pair, old hash invalidated
- **Theft Detection**: if a reused refresh token is detected, all sessions are revoked
- **Social Auth**: Google and Facebook OAuth2 via Passport strategies
- **Account Linking**: social accounts can be linked to existing email accounts

### Real-Time Features

Two WebSocket namespaces powered by Socket.IO:

1. **/vote** — Event track voting in real-time
2. **/playlist** — Collaborative playlist editing with OT

### Event License System

Three license types control event access:

| License      | Description                              |
|-------------|------------------------------------------|
| OPEN        | Anyone can join and participate           |
| INVITED_ONLY| Only invited users can join               |
| GEO_TIME    | Restricted by location radius + time window |

GEO_TIME uses **Haversine formula** for distance calculation and MongoDB **2dsphere index** for geospatial queries.

### Playlist OT (Operational Transformation)

Collaborative playlists use a simplified OT model:
- Each operation carries a `baseVersion`
- Operations are rejected if `baseVersion !== currentVersion`
- Clients must fetch latest state and retry on conflict
- Operations are logged for history/undo capability

## Frontend Architecture

### State Management

```
Zustand Stores
├── authStore      ──▶ JWT tokens, user session (persisted to SecureStore)
├── playerStore    ──▶ Audio playback (expo-av)
├── eventStore     ──▶ Events CRUD + voting
├── playlistStore  ──▶ Playlists CRUD + track management
├── friendStore    ──▶ Friend requests + list
├── musicSearchStore──▶ Deezer search + recent history
└── notificationStore──▶ In-app snackbar notifications
```

### Navigation Structure

```
expo-router (file-based)
├── _layout.tsx         ──▶ Root layout (PaperProvider, AuthGate)
├── index.tsx           ──▶ Entry redirect
├── (auth)/             ──▶ Auth group (login, register, forgot-password)
├── (tabs)/             ──▶ Tab navigation
│   ├── index.tsx       ──▶ Home feed
│   ├── search.tsx      ──▶ Music search
│   ├── events.tsx      ──▶ Events list
│   ├── playlists.tsx   ──▶ Playlists list
│   └── profile.tsx     ──▶ User profile
├── event/[id].tsx      ──▶ Event detail (WebSocket)
├── playlist/[id].tsx   ──▶ Playlist detail (WebSocket)
└── ... (friends, settings, etc.)
```

### Offline Strategy

1. **OfflineQueue**: Queues mutations when offline, replays on reconnect
2. **CacheManager**: TTL-based AsyncStorage cache for reads
3. **useOfflineSync**: Hook that monitors connectivity and triggers sync
4. **OfflineBanner**: Visual indicator when offline

## Database Schema

### Collections

| Collection    | Key Fields                    | Indexes          |
|---------------|-------------------------------|------------------|
| users         | email, username, password     | email (unique)   |
| friends       | requester, recipient, status  | compound         |
| events        | creator, license, location    | 2dsphere         |
| playlists     | owner, tracks, version        | owner            |
| devices       | owner, type, token            | owner            |
| delegations   | delegator, delegate, perms    | compound         |
| subscriptions | user, plan, expiresAt         | user (unique)    |
| request_logs  | method, url, userId, timestamp| TTL (30 days)    |

## Security Layers

1. **Helmet**: CSP, HSTS, X-Frame-Options
2. **CORS**: Whitelist-based origin validation
3. **Rate Limiting**: @nestjs/throttler (60 req/min default)
4. **Input Sanitization**: NoSQL injection + XSS + Prototype pollution
5. **JWT**: Short-lived access tokens (15min) + rotation
6. **bcrypt**: Password hashing (12 rounds)
7. **Validation**: class-validator with whitelist + forbidNonWhitelisted

## IoT Integration (Bonus)

Optional MQTT-based device communication:
- **Dynamic import**: MQTT module loaded only when broker URL configured
- **Topics**: `music-room/devices/{id}/command`, `music-room/devices/{id}/status`
- **Commands**: play, pause, skip, volume, queue
- **Heartbeat**: Periodic health check for connected devices

## Deployment

### Docker

```bash
docker-compose up -d  # MongoDB + API + MQTT
```

### CI/CD

GitHub Actions pipeline:
1. **Backend**: lint → build → test (with MongoDB service)
2. **Frontend**: type-check → expo web export
3. **Security**: npm/yarn audit

## Performance Considerations

- MongoDB atomic operations ($addToSet, $pull, $inc) prevent race conditions
- Fire-and-forget logging for zero-latency request overhead
- TTL index auto-cleans old request logs
- Socket.IO rooms for targeted real-time broadcasts
- Debounced search inputs on frontend
- Pagination for all list endpoints
