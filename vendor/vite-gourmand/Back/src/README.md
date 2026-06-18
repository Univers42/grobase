# Vite Gourmand — Backend API

Production-ready REST API for a restaurant ordering platform built with NestJS, TypeScript, and PostgreSQL.

---

## Table of Contents

- [Project Overview](#project-overview)
- [Tech Stack](#tech-stack)
- [Architecture Overview](#architecture-overview)
- [Architecture Diagram](#architecture-diagram)
- [Project Structure](#project-structure)
- [Environment Configuration](#environment-configuration)
- [Scripts & Commands](#scripts--commands)
- [API Documentation](#api-documentation)
- [Authentication & Authorization](#authentication--authorization)
- [Database Layer](#database-layer)
- [Validation & Error Handling](#validation--error-handling)
- [Security](#security)
- [Testing](#testing)
- [Deployment](#deployment)
- [Development Notes](#development-notes)

---

## Project Overview

This backend serves as the API layer for Vite Gourmand, a restaurant ordering platform. It handles user authentication, menu management, order processing, reviews, analytics, and administrative operations. The API follows REST conventions and is designed for integration with a Vue.js frontend.

---

## Tech Stack

| Category | Technology |
|----------|------------|
| Runtime | Node.js 22 |
| Language | TypeScript 5.x |
| Framework | NestJS 11 |
| Database | PostgreSQL (Supabase) |
| ORM | Prisma 7 with `@prisma/adapter-pg` |
| Authentication | JWT + Passport.js |
| OAuth | Google OAuth 2.0 |
| Validation | class-validator + class-transformer |
| Documentation | Swagger/OpenAPI |
| Caching | @nestjs/cache-manager |
| Rate Limiting | @nestjs/throttler |
| Security | Helmet, bcrypt |
| Email | Nodemailer, Resend |
| Real-time | Socket.io (WebSockets) |
| i18n | nestjs-i18n |
| Testing | Jest + Supertest |
| Linting | ESLint + Prettier |

---

## Architecture Overview

The application follows a modular, layered architecture based on NestJS conventions:

### Layers

| Layer | Responsibility |
|-------|----------------|
| **Controllers** | Handle HTTP requests, route mapping, input extraction |
| **Services** | Business logic, orchestration, data transformations |
| **Modules** | Feature encapsulation, dependency injection configuration |
| **DTOs** | Request/response validation and typing |
| **Guards** | Authentication and authorization enforcement |
| **Filters** | Exception handling and error formatting |
| **Interceptors** | Request/response transformation, logging |
| **Pipes** | Input validation and transformation |

### Design Principles

- **Single Responsibility**: Each module handles one domain (auth, orders, menus, etc.)
- **Dependency Injection**: Services are injected via NestJS DI container
- **Separation of Concerns**: Controllers never access the database directly
- **DTO Validation**: All inputs are validated before reaching services
- **Guard-based Security**: Authentication and authorization at the route level

---

## Architecture Diagram

```mermaid
flowchart TB
    subgraph Client["Client Layer"]
        FE[Vue.js Frontend]
        Mobile[Mobile Apps]
        External[External Services]
    end

    subgraph Gateway["API Gateway"]
        direction TB
        CORS[CORS Middleware]
        Helmet[Helmet Security]
        Compression[Compression]
        RateLimit[Rate Limiter]
    end

    subgraph Guards["Security Layer"]
        direction TB
        JWTGuard[JWT Auth Guard]
        RolesGuard[Roles Guard]
        ThrottlerGuard[Throttler Guard]
    end

    subgraph Interceptors["Cross-cutting Concerns"]
        direction TB
        LoggingInt[Logging Interceptor]
        TransformInt[Transform Interceptor]
        CacheInt[Cache Interceptor]
    end

    subgraph Controllers["Controller Layer"]
        direction TB
        AuthCtrl[Auth Controller]
        MenuCtrl[Menu Controller]
        OrderCtrl[Order Controller]
        UserCtrl[User Controller]
        AdminCtrl[Admin Controller]
        ReviewCtrl[Review Controller]
        OtherCtrl[Other Controllers...]
    end

    subgraph Services["Service Layer"]
        direction TB
        AuthSvc[Auth Service]
        MenuSvc[Menu Service]
        OrderSvc[Order Service]
        UserSvc[User Service]
        AdminSvc[Admin Service]
        MailSvc[Mail Service]
        OtherSvc[Other Services...]
    end

    subgraph DataLayer["Data Access Layer"]
        direction TB
        PrismaService[Prisma Service]
        CacheManager[Cache Manager]
    end

    subgraph Database["Database Layer"]
        direction TB
        PostgreSQL[(PostgreSQL)]
        Supabase[Supabase Cloud]
    end

    subgraph External["External Services"]
        direction TB
        Google[Google OAuth]
        Resend[Resend Email]
        Unsplash[Unsplash API]
    end

    Client --> Gateway
    Gateway --> Guards
    Guards --> Interceptors
    Interceptors --> Controllers
    Controllers --> Services
    Services --> DataLayer
    DataLayer --> Database
    Services --> External

    subgraph Pipes["Validation"]
        ValidationPipe[Custom Validation Pipe]
        ParseIntPipe[Safe ParseInt Pipe]
    end

    subgraph Filters["Error Handling"]
        HttpFilter[HTTP Exception Filter]
        AllFilter[All Exceptions Filter]
    end

    Controllers -.-> Pipes
    Controllers -.-> Filters
```

### Module Dependency Diagram

```mermaid
flowchart LR
    subgraph Core["Core Modules"]
        AppModule[App Module]
        PrismaModule[Prisma Module]
        ConfigModule[Config Module]
    end

    subgraph Auth["Authentication"]
        AuthModule[Auth Module]
        SessionModule[Session Module]
    end

    subgraph Domain["Domain Modules"]
        MenuModule[Menu Module]
        DishModule[Dish Module]
        OrderModule[Order Module]
        UserModule[User Module]
        ReviewModule[Review Module]
    end

    subgraph Reference["Reference Data"]
        DietModule[Diet Module]
        AllergenModule[Allergen Module]
        ThemeModule[Theme Module]
        RoleModule[Role Module]
    end

    subgraph Admin["Administration"]
        AdminModule[Admin Module]
        AnalyticsModule[Analytics Module]
        KanbanModule[Kanban Module]
    end

    subgraph Support["Support Services"]
        MailModule[Mail Module]
        LoggingModule[Logging Module]
        GdprModule[GDPR Module]
        ContactModule[Contact Module]
    end

    AppModule --> PrismaModule
    AppModule --> ConfigModule
    AppModule --> AuthModule
    AppModule --> Domain
    AppModule --> Reference
    AppModule --> Admin
    AppModule --> Support

    AuthModule --> PrismaModule
    AuthModule --> MailModule
    Domain --> PrismaModule
    Domain --> AuthModule
    Admin --> PrismaModule
    Admin --> AuthModule
```

---

## Project Structure

```
src/
├── main.ts                    # Application entry point
├── app.module.ts              # Root module, imports all feature modules
├── app.controller.ts          # Health check and root endpoints
├── app.service.ts             # Application-level service
│
├── common/                    # Shared utilities
│   ├── guards/                # JWT, Roles, Optional auth guards
│   ├── filters/               # HTTP and global exception filters
│   ├── interceptors/          # Logging, transform interceptors
│   ├── pipes/                 # Validation, ParseInt pipes
│   ├── decorators/            # @Public, @Roles, @CurrentUser
│   ├── dto/                   # Pagination, API response DTOs
│   └── types/                 # Request types, interfaces
│
├── prisma/                    # Database service
│   ├── prisma.module.ts
│   └── prisma.service.ts      # Prisma client with lifecycle hooks
│
├── auth/                      # Authentication module
│   ├── auth.module.ts
│   ├── auth.controller.ts     # Login, register, password reset
│   ├── auth.service.ts        # Auth business logic
│   ├── password.service.ts    # Password hashing
│   ├── token.service.ts       # JWT operations
│   ├── strategies/            # JWT and Google OAuth strategies
│   └── dto/                   # Auth-related DTOs
│
├── user/                      # User management
├── menu/                      # Menu CRUD and listing
├── dish/                      # Dish management
├── order/                     # Order processing and status
├── review/                    # Customer reviews
├── admin/                     # Admin operations
├── analytics/                 # Dashboard statistics
├── working-hours/             # Restaurant hours
├── diet/                      # Dietary categories
├── allergen/                  # Allergen reference data
├── theme/                     # Menu themes
├── role/                      # User roles
├── mail/                      # Email service
├── logging/                   # Real-time log streaming
├── gdpr/                      # Data privacy compliance
├── loyalty/                   # Points and rewards
├── discount/                  # Promo codes
├── delivery/                  # Delivery assignments
├── contact/                   # Contact form messages
├── support/                   # Support tickets
├── kanban/                    # Task management
├── session/                   # Session management
├── image/                     # Image handling
├── unsplash/                  # Unsplash API integration
├── seed/                      # Database seeding
├── i18n/                      # Translation files (en, fr)
│
├── Model/                     # Prisma schema
│   └── prisma/
│       └── schema.prisma      # Database schema definition
│
└── test/                      # Test suites
    ├── e2e/                   # End-to-end tests (43 suites)
    ├── unit_tests/            # Unit tests
    └── utils/                 # Test utilities
```

---

## Environment Configuration

The application uses `.env` files for configuration. Required variables:

```bash
# Database
DATABASE_URL=postgresql://user:password@host:port/database

# Authentication
JWT_SECRET=your-secure-secret-key

# Google OAuth (optional)
GOOGLE_CLIENT_ID=your-google-client-id
GOOGLE_CLIENT_SECRET=your-google-client-secret
GOOGLE_CALLBACK_URL=http://localhost:3000/api/auth/google/callback

# Email Service
RESEND_API_KEY=your-resend-api-key
MAIL_FROM=noreply@example.com

# External APIs
UNSPLASH_ACCESS_KEY=your-unsplash-key

# Frontend
FRONTEND_URL=http://localhost:5173

# Environment
NODE_ENV=development
PORT=3000
```

---

## Scripts & Commands

| Command | Description |
|---------|-------------|
| `npm run start:dev` | Start development server with hot reload |
| `npm run start` | Start production server |
| `npm run start:prod` | Start from compiled dist |
| `npm run build` | Compile TypeScript to JavaScript |
| `npm run lint` | Run ESLint with auto-fix |
| `npm run format` | Format code with Prettier |
| `npm test` | Run unit tests |
| `npm run test:e2e` | Run end-to-end tests |
| `npm run test:cov` | Run tests with coverage report |
| `npm run seed` | Seed database with sample data |
| `npm run seed:images` | Update menu images from Unsplash |

---

## API Documentation

Interactive API documentation is available via Swagger UI:

- **Development**: `http://localhost:3000/api/docs`
- **Production**: `https://your-domain.com/api/docs`

### Main Endpoints

| Resource | Endpoints |
|----------|-----------|
| Auth | `POST /api/auth/register`, `POST /api/auth/login`, `GET /api/auth/me` |
| Users | `GET /api/users/me`, `PUT /api/users/me`, `DELETE /api/users/me` |
| Menus | `GET /api/menus`, `GET /api/menus/:id`, `POST /api/menus` |
| Dishes | `GET /api/dishes`, `GET /api/dishes/:id` |
| Orders | `GET /api/orders`, `POST /api/orders`, `POST /api/orders/:id/cancel` |
| Reviews | `GET /api/reviews`, `POST /api/reviews` |
| Admin | `GET /api/admin/users`, `PUT /api/admin/users/:id/role` |
| Analytics | `GET /api/analytics/dashboard` |

---

## Authentication & Authorization

### Authentication Flow

1. User registers or logs in via `/api/auth/register` or `/api/auth/login`
2. Server returns JWT access token
3. Client includes token in `Authorization: Bearer <token>` header
4. JWT Guard validates token on protected routes
5. User payload is extracted and injected via `@CurrentUser()` decorator

### OAuth Support

Google OAuth is supported for social login:
- Passport.js Google Strategy
- Popup-based authentication flow
- Automatic user creation on first OAuth login

### Authorization

Role-based access control (RBAC) with the following roles:

| Role | Permissions |
|------|-------------|
| `client` | View menus, place orders, write reviews |
| `employee` | Manage orders, update statuses |
| `manager` | All employee permissions + analytics |
| `admin` | Full access to all resources |

Usage:
```typescript
@Roles('admin', 'manager')
@Get('dashboard')
getDashboard() { ... }
```

---

## Database Layer

### Prisma ORM

- Schema defined in `src/Model/prisma/schema.prisma`
- Uses `@prisma/adapter-pg` for PostgreSQL connection pooling
- Automatic migrations via Prisma Migrate

### Main Entities

| Entity | Description |
|--------|-------------|
| User | Customer and staff accounts |
| Menu | Restaurant menus with dishes |
| Dish | Individual menu items |
| Order | Customer orders with items |
| OrderItem | Line items in orders |
| Review | Customer reviews and ratings |
| Role | User role definitions |
| Diet | Dietary categories (vegan, halal, etc.) |
| Allergen | Allergen information |
| Theme | Menu themes/occasions |
| Discount | Promo codes and discounts |
| LoyaltyPoints | Customer loyalty program |

### Database Connection

```typescript
@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit {
  async onModuleInit() {
    await this.$connect();
  }
}
```

---

## Validation & Error Handling

### Input Validation

All request inputs are validated using class-validator decorators:

```typescript
export class CreateOrderDto {
  @IsArray()
  @ArrayMinSize(1)
  @ValidateNested({ each: true })
  @Type(() => OrderItemDto)
  items: OrderItemDto[];

  @IsOptional()
  @IsString()
  @MaxLength(500)
  notes?: string;
}
```

### Validation Pipe

Custom validation pipe with detailed error messages:
- Whitelist mode (strips unknown properties)
- ForbidNonWhitelisted (rejects unknown properties)
- Transform mode (auto-converts types)

### Exception Filters

Two-layer exception handling:

1. **HttpExceptionFilter**: Handles known HTTP exceptions
2. **AllExceptionsFilter**: Catches unhandled errors, logs stack traces

Standard error response format:
```json
{
  "success": false,
  "statusCode": 400,
  "message": "Validation failed",
  "error": "BadRequestException",
  "path": "/api/orders",
  "timestamp": "2026-02-09T15:30:00.000Z"
}
```

---

## Security

### Implemented Measures

| Measure | Implementation |
|---------|----------------|
| HTTPS | Enforced via Fly.io (`force_https: true`) |
| Helmet | Security headers (XSS, HSTS, etc.) |
| CORS | Configured for frontend origin |
| Rate Limiting | Throttler: 3/sec, 20/10sec, 100/min |
| Password Hashing | bcrypt with salt rounds |
| JWT | Signed tokens with expiration |
| Input Validation | class-validator on all DTOs |
| SQL Injection | Prevented via Prisma parameterized queries |
| XSS | Input sanitization, CSP headers |
| CSRF | Token-based authentication (not cookies) |

### Security Tests

Comprehensive E2E security test suites:
- SQL injection prevention
- XSS attack prevention
- Path traversal protection
- Authentication bypass attempts
- Authorization boundary tests
- Timing attack resistance
- Mass assignment protection
- NoSQL injection (MongoDB patterns)

---

## Testing

### Test Suites

| Type | Suites | Tests |
|------|--------|-------|
| Unit | 38 | 318 |
| E2E | 43 | 346 |
| **Total** | **81** | **664** |

### Running Tests

```bash
# Unit tests
npm test

# E2E tests (requires database)
npm run test:e2e

# With coverage
npm run test:cov
```

### E2E Test Categories

- Authentication (login, register, password)
- CRUD operations (menus, dishes, orders)
- Authorization (role-based access)
- Validation (edge cases, invalid inputs)
- Security (injection, XSS, traversal)
- API contract (response formats)
- Pagination and filtering

---

## Deployment

### Docker

Multi-stage Dockerfile for production:
1. Backend build stage
2. Frontend build stage
3. Production image (Node.js Alpine)

```bash
docker build -t vite-gourmand .
docker run -p 8080:8080 --env-file .env vite-gourmand
```

### Fly.io

Deployed on Fly.io with:
- Region: CDG (Paris)
- Auto-scaling (0-1 machines)
- Health checks every 15s
- 1GB RAM, 1 vCPU

```bash
fly deploy
fly logs
fly status
```

### CI/CD

- Unit tests run at build time
- E2E tests available on demand
- Health check endpoint: `GET /api`

---

## Development Notes

### Code Organization

- Each feature is a self-contained module
- Services are split when exceeding ~300 lines
- DTOs are co-located with their modules
- Shared code lives in `common/`

### Scalability Considerations

- Stateless design (no server-side sessions)
- Database connection pooling via `@prisma/adapter-pg`
- Response caching for read-heavy endpoints
- Rate limiting to prevent abuse

### Maintainability

- TypeScript strict mode enabled
- ESLint + Prettier for consistent style
- Comprehensive test coverage
- Swagger documentation auto-generated

### Performance

- Response compression (gzip)
- In-memory caching (60s TTL)
- Pagination on list endpoints
- Database indexes on frequent queries

---

## Referential Compliance

| Requirement | Status | Implementation |
|-------------|--------|----------------|
| Build a backend API | ✅ | NestJS REST API with 40+ endpoints |
| Authentication & Authorization | ✅ | JWT + OAuth, RBAC with 4 roles |
| Database connection | ✅ | PostgreSQL via Prisma ORM |
| Clean architecture | ✅ | Modular layers (controllers, services, modules) |
| Error handling | ✅ | Global filters, structured responses |
| Validation | ✅ | class-validator DTOs, custom pipes |
| Security | ✅ | Helmet, CORS, rate limiting, bcrypt |
| Frontend integration | ✅ | CORS, SPA fallback, static file serving |
| Version control | ✅ | Git with conventional commits |
| Testing | ✅ | 664 tests (unit + E2E) |
| Deployment | ✅ | Docker + Fly.io, health checks |

---

## License

This project is developed for educational purposes as part of the Studi curriculum.
