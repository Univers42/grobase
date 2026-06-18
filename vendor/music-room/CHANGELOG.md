# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Frontend component tests for stores and utilities
- Backend e2e integration tests
- Health check endpoint with readiness/liveness probes
- Configuration validation with Joi schema
- Custom pipes: ParseObjectId, Trim, ParsePagination
- Exception filters for MongoDB and global errors
- Role-based access control (RBAC) decorator and guard
- Deep linking configuration for mobile navigation
- Frontend Jest configuration and test setup

## [0.17.0] - 2025-01-15

### Added
- CONTRIBUTING.md with development guidelines
- ARCHITECTURE.md with system design documentation
- DEPLOYMENT.md with production deployment guide
- Additional UI components: ErrorBoundary, SplashScreen, TagList, PasswordStrengthBar, InfiniteList
- Backend controller and guard unit tests
- Frontend utility tests for formatters, validators, helpers

## [0.16.0] - 2025-01-15

### Added
- Docker multi-stage builds for backend and frontend
- docker-compose.yml with MongoDB and MQTT services
- ESLint/Prettier configuration for consistent code style
- VS Code workspace settings and extensions
- Seed scripts for development data

## [0.15.0] - 2025-01-15

### Added
- k6 load testing scripts (standard + spike)
- Performance thresholds and custom metrics

## [0.14.0] - 2025-01-15

### Added
- GitHub Actions CI/CD pipeline
- Backend unit tests with Jest
- Code coverage reporting

## [0.13.0] - 2025-01-15

### Added
- Swagger/OpenAPI documentation for all endpoints
- API tags and operation descriptions

## [0.12.0] - 2025-01-15

### Added
- Security hardening with Helmet
- NoSQL injection prevention middleware
- XSS sanitization
- Rate limiting with @nestjs/throttler
- CORS configuration

## [0.11.0] - 2025-01-15

### Added
- Offline support with queue and cache managers
- NetInfo connectivity monitoring
- AsyncStorage-based cache with TTL

## [0.10.0] - 2025-01-15

### Added
- IoT device management via MQTT
- Device pairing and heartbeat monitoring
- Playback delegation to IoT devices

## [0.9.0] - 2025-01-15

### Added
- Complete Expo React Native frontend
- File-based routing with expo-router
- Authentication screens (login, register, forgot password)
- Tab navigation (home, search, events, playlists, profile)
- Event and playlist management screens
- Zustand state management with persistence
- react-native-paper MD3 theming
- Audio playback with expo-av
- MiniPlayer component
- Real-time WebSocket integration

## [0.8.0] - 2025-01-15

### Added
- Subscription module with plan tiers
- Feature gates based on subscription level
- Plan comparison and upgrade flow

## [0.7.0] - 2025-01-15

### Added
- Request logging module with MongoDB TTL
- Fire-and-forget logging interceptor
- Log querying endpoints with filters

## [0.6.0] - 2025-01-15

### Added
- Control delegation module
- Device binding and permission management
- Temporary delegation tokens

## [0.5.0] - 2025-01-15

### Added
- Collaborative playlist editor
- Operational Transform (OT) for concurrent edits
- Real-time playlist sync via WebSocket

## [0.4.0] - 2025-01-15

### Added
- Event management with geolocation
- Track voting system with atomic MongoDB operations
- License-based geographic restrictions (Haversine formula)
- Real-time vote WebSocket gateway

## [0.3.0] - 2025-01-15

### Added
- Deezer music search API proxy
- Track, artist, and album detail endpoints
- 30-second preview URL support

## [0.2.0] - 2025-01-15

### Added
- User profile management
- Privacy levels (public, friends, private)
- Friend request system

## [0.1.0] - 2025-01-15

### Added
- JWT authentication with access/refresh token rotation
- Google and Facebook OAuth strategies
- Email verification and password reset
- Single-use refresh token with theft detection
- User schema with comprehensive profile fields

## [0.0.1] - 2025-01-15

### Added
- Initial project scaffolding
- NestJS backend with MongoDB/Mongoose
- Expo React Native frontend
- Project README and Makefile
