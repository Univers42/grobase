# MongoDB — Analytics & Logging Database

> **Purpose:** Non-transactional, high-write data — user activity tracking, search analytics, dashboard statistics, audit logs, and denormalized order snapshots for fast reads.
> All transactional data lives in [PostgreSQL](./relational_database.md).

---

## Why MongoDB for These Use Cases?

| Criteria | PostgreSQL | MongoDB ✅ |
|----------|-----------|-----------|
| **Activity logs** (high write volume) | Bloats tables, slows queries | Append-only, TTL auto-cleanup |
| **Search analytics** (flexible schema) | Rigid schema, migrations needed | Schema-less, evolves freely |
| **Dashboard stats** (pre-computed) | Requires materialized views | Native aggregation pipeline |
| **Audit trail** (JSON diffs) | JSONB possible but slower | Native document storage |
| **Order snapshots** (denormalized) | Would duplicate relational data | Designed for denormalization |
| **Real-time counters** | Row-level locking | Atomic `$inc` operations |

---

## Data Retention Policy

| Collection | TTL | Rationale |
|-----------|-----|-----------|
| `user_activity_logs` | 30 days | Session data, low long-term value |
| `search_analytics` | 30 days | Search patterns, regenerable |
| `audit_logs` | 90 days | Compliance requirement |
| `order_snapshots` | 180 days | Historical reference |
| `menu_analytics` | 365 days | Business intelligence |
| `revenue_by_menu` | 365 days | Subject requirement: CA par menu |
| `dashboard_stats` | 365 days | Year-over-year comparison |

> ⚠️ **Atlas free tier:** 512 MB limit. The service monitors storage at 85% threshold and triggers automatic cleanup by priority.

---

## Collection Schemas

```mermaid
erDiagram

    %% ========================================
    %% ANALYTICS
    %% ========================================

    MenuAnalytics {
        ObjectId _id PK
        int menuId "FK to PostgreSQL Menu.id"
        string menuTitle "Denormalized"
        string period "2026-02-01"
        string periodType "daily, weekly, monthly"
        int viewCount "Atomic $inc"
        int orderCount "Atomic $inc"
        float totalRevenue
        float averageRating
        int ratingCount
        object ordersByDiet "map string to number"
        object ordersByTheme "map string to number"
        array peakHours "array of int"
        date createdAt
        date updatedAt
    }

    RevenueByMenu {
        ObjectId _id PK
        int menuId "FK to PostgreSQL Menu.id"
        string menuTitle "Denormalized"
        string period "2026-02"
        string periodType "daily, weekly, monthly"
        int orderCount "Atomic $inc"
        float totalRevenue "Atomic $inc"
        float averageOrderValue
        int totalPersons "Sum of person_number"
        float deliveryRevenue "Sum of delivery_price"
        float discountTotal "Sum of discount_amount"
        date createdAt
        date updatedAt
    }

    DashboardStats {
        ObjectId _id PK
        string date UK "2026-02-01"
        string type "daily, weekly, monthly"
        int totalOrders
        int completedOrders
        int cancelledOrders
        int pendingOrders
        float totalRevenue
        float averageOrderValue
        int newUsers
        int activeUsers
        int returningUsers
        array topMenus "array of id title count"
        object dietDistribution "map string to number"
        object ordersByHour "map string to number"
        object ordersByDayOfWeek "map string to number"
        date computedAt
    }

    SearchAnalytics {
        ObjectId _id PK
        string query
        string normalizedQuery "lowercase trimmed"
        int resultsCount
        array clickedResults "array of menuId"
        object filters "diet theme priceRange"
        int userId "Nullable"
        string sessionId
        boolean convertedToOrder
        date timestamp "TTL 30 days"
    }

    %% ========================================
    %% USER BEHAVIOR
    %% ========================================

    UserActivityLog {
        ObjectId _id PK
        int userId "FK to PostgreSQL User.id"
        string sessionId
        string action "view_menu, place_order, search, login"
        string targetType "menu, dish, order, category"
        int targetId
        string targetName "Denormalized"
        object searchContext "query and filters"
        string ipAddress
        string userAgent
        date timestamp "TTL 30 days"
    }

    %% ========================================
    %% AUDIT & COMPLIANCE
    %% ========================================

    AuditLog {
        ObjectId _id PK
        int userId "Nullable for system actions"
        string userEmail "Denormalized"
        string userRole "Denormalized"
        string action "create, update, delete, login"
        string entityType "user, order, menu, role"
        int entityId
        object previousState "JSON diff"
        object newState "JSON diff"
        array changedFields "array of string"
        string ipAddress
        string userAgent
        date timestamp "TTL 90 days"
    }

    %% ========================================
    %% DENORMALIZED SNAPSHOTS
    %% ========================================

    OrderSnapshot {
        ObjectId _id PK
        int orderId UK "FK to PostgreSQL Order.id"
        string orderNumber
        object user "id email firstName city"
        date orderDate
        date deliveryDate
        string deliveryHour
        int personNumber
        string status
        float menuPrice
        float deliveryPrice
        float discountAmount
        float totalPrice
        array menus "id title price diet dishes"
        boolean materialLending
        array tags "weekend large_party vip"
        date createdAt
    }

    %% ========================================
    %% RELATIONSHIPS (logical not enforced)
    %% ========================================

    MenuAnalytics ||--|| RevenueByMenu : "revenue_detail"
    MenuAnalytics ||--|| DashboardStats : "aggregated_into"
    UserActivityLog ||--o{ SearchAnalytics : "generates"
    UserActivityLog ||--o{ MenuAnalytics : "feeds"
    OrderSnapshot ||--o{ DashboardStats : "aggregated_into"
    OrderSnapshot ||--o{ RevenueByMenu : "feeds"
    AuditLog ||--o{ OrderSnapshot : "tracks_changes_to"
```

---

## Indexes

```javascript
// menu_analytics
db.menu_analytics.createIndex({ menuId: 1, period: 1 }, { unique: true });
db.menu_analytics.createIndex({ periodType: 1, period: -1 });

// user_activity_logs
db.user_activity_logs.createIndex({ userId: 1, timestamp: -1 });
db.user_activity_logs.createIndex({ sessionId: 1 });
db.user_activity_logs.createIndex({ action: 1, timestamp: -1 });
db.user_activity_logs.createIndex({ timestamp: 1 }, { expireAfterSeconds: 2592000 }); // 30 days

// order_snapshots
db.order_snapshots.createIndex({ orderId: 1 }, { unique: true });
db.order_snapshots.createIndex({ "user.id": 1 });
db.order_snapshots.createIndex({ orderDate: -1 });
db.order_snapshots.createIndex({ status: 1 });

// dashboard_stats
db.dashboard_stats.createIndex({ date: 1, type: 1 }, { unique: true });

// audit_logs
db.audit_logs.createIndex({ entityType: 1, entityId: 1 });
db.audit_logs.createIndex({ userId: 1, timestamp: -1 });
db.audit_logs.createIndex({ timestamp: 1 }, { expireAfterSeconds: 7776000 }); // 90 days

// search_analytics
db.search_analytics.createIndex({ normalizedQuery: 1 });
db.search_analytics.createIndex({ timestamp: -1 });
db.search_analytics.createIndex({ timestamp: 1 }, { expireAfterSeconds: 2592000 }); // 30 days
```

---

## Aggregation Pipelines

```javascript
// Top 10 most ordered menus this month
db.menu_analytics.aggregate([
  { $match: { periodType: "monthly", period: "2026-02" } },
  { $sort: { orderCount: -1 } },
  { $limit: 10 },
  { $project: { menuTitle: 1, orderCount: 1, totalRevenue: 1, averageRating: 1 } }
]);

// Peak ordering hours this week
db.order_snapshots.aggregate([
  { $match: { orderDate: { $gte: new Date("2026-02-03") } } },
  { $group: { _id: { $hour: "$orderDate" }, count: { $sum: 1 } } },
  { $sort: { count: -1 } }
]);

// Search queries that never convert to orders
db.search_analytics.aggregate([
  { $match: { convertedToOrder: false } },
  { $group: { _id: "$normalizedQuery", count: { $sum: 1 } } },
  { $sort: { count: -1 } },
  { $limit: 20 }
]);

// User journey: what actions lead to orders
db.user_activity_logs.aggregate([
  { $match: { action: "place_order" } },
  { $lookup: {
      from: "user_activity_logs",
      let: { uid: "$userId", ts: "$timestamp" },
      pipeline: [
        { $match: { $expr: { $and: [
          { $eq: ["$userId", "$$uid"] },
          { $lt: ["$timestamp", "$$ts"] },
          { $gt: ["$timestamp", { $subtract: ["$$ts", 3600000] }] }
        ]}}}
      ],
      as: "prior_actions"
  }},
  { $unwind: "$prior_actions" },
  { $group: { _id: "$prior_actions.action", count: { $sum: 1 } } },
  { $sort: { count: -1 } }
]);

// === SUBJECT REQUIREMENT: Chiffre d'affaires par menu avec filtres ===
// Revenue by menu with date range filter (admin dashboard charts)
db.revenue_by_menu.aggregate([
  { $match: {
    periodType: "monthly",
    period: { $gte: "2026-01", $lte: "2026-06" }
  }},
  { $group: {
    _id: { menuId: "$menuId", menuTitle: "$menuTitle" },
    totalRevenue: { $sum: "$totalRevenue" },
    totalOrders: { $sum: "$orderCount" },
    totalPersons: { $sum: "$totalPersons" },
    avgOrderValue: { $avg: "$averageOrderValue" }
  }},
  { $sort: { totalRevenue: -1 } }
]);

// Revenue for a specific menu over time (line chart)
db.revenue_by_menu.aggregate([
  { $match: { menuId: 1, periodType: "monthly" } },
  { $sort: { period: 1 } },
  { $project: {
    period: 1,
    totalRevenue: 1,
    orderCount: 1,
    averageOrderValue: 1
  }}
]);

// Compare all menus side by side (bar chart - subject requirement)
db.revenue_by_menu.aggregate([
  { $match: { periodType: "monthly", period: "2026-02" } },
  { $project: {
    menuTitle: 1,
    orderCount: 1,
    totalRevenue: 1
  }},
  { $sort: { orderCount: -1 } }
]);
```

---

## Data Flow: PostgreSQL ↔ MongoDB

```
┌─────────────────────┐         ┌─────────────────────┐
│     PostgreSQL      │         │      MongoDB         │
│  (Source of Truth)  │         │   (Analytics Layer)  │
├─────────────────────┤         ├─────────────────────┤
│                     │         │                     │
│  User creates order ├────────►│  OrderSnapshot      │
│                     │  sync   │  (denormalized)     │
│  Order status       ├────────►│  DashboardStats     │
│  changes            │  event  │  (aggregated)       │
│                     │         │                     │
│  Menu published     ├────────►│  MenuAnalytics      │
│                     │  event  │  (view/order count) │
│                     │         │                     │
│  User logs in       ├────────►│  UserActivityLog    │
│                     │  event  │  AuditLog           │
│                     │         │                     │
│  ◄── Query results ─┤         │  Search, Dashboard  │
│  (for display only) │◄────────┤  pre-computed       │
│                     │  read   │                     │
└─────────────────────┘         └─────────────────────┘
```

> **Rule:** PostgreSQL is always the source of truth. MongoDB holds derived, expendable data. If MongoDB goes down, the application still works — analytics features are just unavailable.
