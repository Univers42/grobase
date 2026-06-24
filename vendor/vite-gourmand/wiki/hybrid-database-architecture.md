# Hybrid Database Architecture

This document explains how Vite Gourmand uses both **PostgreSQL** (relational) and **MongoDB** (non-relational) databases together.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Frontend (React)                         │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                      NestJS Backend API                         │
│  ┌─────────────────────┐      ┌─────────────────────────────┐  │
│  │  Prisma ORM         │      │  MongoDB Driver             │  │
│  │  (Transactional)    │      │  (Analytics)                │  │
│  └──────────┬──────────┘      └──────────────┬──────────────┘  │
└─────────────│────────────────────────────────│──────────────────┘
              │                                │
              ▼                                ▼
┌─────────────────────────┐    ┌──────────────────────────────────┐
│  PostgreSQL             │    │  MongoDB                         │
│  ─────────────────────  │    │  ────────────────────────────────│
│  • Users, Roles         │    │  • Menu Analytics                │
│  • Orders (ACID)        │    │  • User Activity Logs            │
│  • Menus, Dishes        │    │  • Order Snapshots (denormalized)│
│  • Diets, Themes        │    │  • Dashboard Statistics          │
│  • Allergens            │    │  • Audit Logs                    │
│  • Working Hours        │    │  • Search Analytics              │
└─────────────────────────┘    └──────────────────────────────────┘
```

## Why Both Databases?

### PostgreSQL (Relational)
Best for:
- **Transactional data** requiring ACID compliance (orders, payments)
- **Referential integrity** (foreign keys between users, orders, menus)
- **Structured queries** with complex JOINs
- **Data that changes frequently** and needs consistency

### MongoDB (Non-Relational)
Best for:
- **Analytics & statistics** (aggregations, time-series)
- **Logging** (user activity, audit trails)
- **Denormalized data** for fast reads
- **Flexible schemas** that may evolve
- **High write throughput** (event logging)
- **TTL (Time-To-Live)** for automatic data cleanup

## Data Distribution

### PostgreSQL Tables (Prisma Schema)

| Table | Purpose | Why PostgreSQL? |
|-------|---------|-----------------|
| User | User accounts | Authentication, relationships |
| Role | User roles | Authorization, referential integrity |
| Order | Customer orders | ACID transactions, payment tracking |
| Menu | Menu catalog | Complex relationships (dishes, diets) |
| Dish | Individual dishes | Many-to-many with allergens |
| Diet | Dietary restrictions | Reference data |
| Theme | Menu themes | Reference data |
| Allergen | Food allergens | Many-to-many with dishes |
| Publish | User reviews | Related to users |
| WorkingHours | Business hours | Configuration data |

### MongoDB Collections

| Collection | Purpose | Why MongoDB? |
|------------|---------|--------------|
| menu_analytics | Track menu views, orders, revenue | Time-series aggregation, flexible metrics |
| user_activity_logs | Log user actions (views, clicks, searches) | High write volume, 90-day TTL auto-cleanup |
| order_snapshots | Denormalized order data | Fast reads for dashboards, no JOINs needed |
| dashboard_stats | Pre-computed statistics | Aggregate data, quick dashboard loading |
| audit_logs | Track data changes | Compliance, 1-year TTL auto-cleanup |
| search_analytics | Track search patterns | Flexible schema, recommendations |

## Data Flow Examples

### 1. User Places an Order

```
1. Frontend → POST /orders
2. Backend validates with Prisma (PostgreSQL)
3. Prisma creates Order record (ACID transaction)
4. Backend creates OrderSnapshot in MongoDB (denormalized copy)
5. Backend updates menu_analytics (increment order count)
6. Backend logs audit_log entry
7. Response to frontend
```

### 2. Admin Views Dashboard

```
1. Frontend → GET /dashboard/stats
2. Backend queries dashboard_stats from MongoDB (pre-computed)
3. Fast response with no complex JOINs
4. Background job updates stats periodically
```

### 3. User Searches for Menus

```
1. Frontend → GET /menus/search?q=vegetarian
2. Backend queries PostgreSQL for menu data
3. Backend logs to search_analytics (MongoDB)
4. Later: analyze popular searches for recommendations
```

## MongoDB Schema Details

### menu_analytics
```javascript
{
  menuId: 1,                    // FK to PostgreSQL
  menuTitle: "Italian Feast",   // Denormalized
  period: "2026-02",            // Monthly bucket
  periodType: "monthly",
  viewCount: 150,
  orderCount: 45,
  totalRevenue: 2250.00,
  averageRating: 4.5,
  ordersByDiet: { vegetarian: 12, vegan: 8 },
  ordersByTheme: { italian: 45 },
  peakHours: [12, 13, 19, 20]
}
```

### user_activity_logs (90-day TTL)
```javascript
{
  userId: 123,
  sessionId: "abc-123",
  action: "view_menu",
  targetType: "menu",
  targetId: 1,
  targetName: "Italian Feast",
  timestamp: ISODate("2026-02-01T12:00:00Z")
}
```

### order_snapshots
```javascript
{
  orderId: 456,                 // FK to PostgreSQL
  orderNumber: "ORD-2026-0001",
  user: {
    id: 123,
    email: "user@example.com",
    firstName: "John",
    city: "Paris"
  },
  menus: [{
    id: 1,
    title: "Italian Feast",
    dishes: [{ id: 10, title: "Pizza", allergens: ["gluten"] }]
  }],
  totalPrice: 150.00,
  status: "completed",
  createdAt: ISODate("2026-02-01T12:00:00Z")
}
```

## Automation

### MongoDB Initialization
The `mongo-init.js` script runs automatically when MongoDB starts for the first time:
- Creates all 6 collections with schema validation
- Creates indexes for fast queries
- Sets up TTL indexes for automatic cleanup

### Manual Commands
```bash
make mongosh          # Open MongoDB shell
make mongo-init       # Re-run initialization script
make wait-for-mongo   # Wait for MongoDB to be ready
```

## Usage in Code

### Inject AnalyticsService
```typescript
import { AnalyticsService } from './mongo';

@Injectable()
export class OrderService {
  constructor(private analytics: AnalyticsService) {}

  async createOrder(data: CreateOrderDto) {
    // 1. Create in PostgreSQL
    const order = await this.prisma.order.create({ data });

    // 2. Create snapshot in MongoDB
    await this.analytics.createOrderSnapshot({
      orderId: order.id,
      orderNumber: order.order_number,
      // ... denormalized data
    });

    // 3. Update menu analytics
    for (const menu of order.menus) {
      await this.analytics.recordMenuOrder(
        menu.id,
        menu.title,
        menu.price_per_person * order.person_number
      );
    }

    return order;
  }
}
```

### Track User Activity
```typescript
await this.analytics.trackMenuView(userId, menuId, menuTitle, sessionId);
await this.analytics.trackSearch(query, resultsCount, filters, userId);
```

### Get Dashboard Stats
```typescript
const stats = await this.analytics.getDashboardStats('2026-02-01', 'daily');
const topMenus = await this.analytics.getTopMenus(10, 'monthly');
const popularSearches = await this.analytics.getPopularSearches(20);
```

## Best Practices

1. **PostgreSQL for source of truth** - All core data lives here
2. **MongoDB for derived data** - Analytics, snapshots, logs
3. **Denormalize carefully** - Store frequently accessed data together in MongoDB
4. **Use TTL indexes** - Automatically clean up old logs
5. **Async writes to MongoDB** - Don't block main requests for analytics
6. **Batch updates** - Aggregate stats periodically, not per-request

## Files

| File | Description |
|------|-------------|
| `backend/src/mongo/schemas.ts` | TypeScript interfaces for MongoDB documents |
| `backend/src/mongo/analytics.service.ts` | NestJS service for MongoDB operations |
| `backend/src/mongo/analytics.module.ts` | NestJS module for analytics |
| `data/mongo-init.js` | MongoDB initialization script |
| `docker-compose.yml` | MongoDB container configuration |
| `backend/.env` | MongoDB connection string |
