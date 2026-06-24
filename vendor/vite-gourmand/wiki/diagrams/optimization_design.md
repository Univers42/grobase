# Performance Optimization Strategy

---

## PostgreSQL Optimization

### Indexing Strategy

| Index | Type | Purpose |
|-------|------|---------|
| `users(email)` | Unique, partial (`WHERE is_deleted = false`) | Login queries |
| `users(role_id)` | B-tree | Role-based filtering |
| `orders(order_number)` | Unique | Order lookup |
| `orders(user_id, order_date DESC)` | Composite | User order history |
| `orders(status)` | B-tree | Kanban board filtering |
| `orders(delivery_date)` | B-tree | Scheduling |
| `orders(assigned_to)` | Partial (`WHERE assigned_to IS NOT NULL`) | Employee workload |
| `menus(status)` | B-tree | Published menu listing |
| `menus(diet_id, theme_id)` | Composite | Menu filtering |
| `reviews(is_approved, created_at DESC)` | Composite | Moderation queue |
| `reviews(menu_id)` | Partial (`WHERE is_approved = true`) | Menu ratings |
| `notifications(user_id, is_read)` | Partial (`WHERE is_read = false`) | Unread count |
| `support_tickets(status, priority)` | Composite | Ticket dashboard |

### Query Optimization

- **Avoid N+1:** Use Prisma `include` / `select` for eager loading
- **Pagination:** Cursor-based for real-time lists (orders, notifications)
- **Connection pooling:** Prisma pool (max 20 connections)
- **Prepared statements:** Automatic via Prisma ORM
- **VACUUM:** Scheduled weekly for tables with frequent updates

---

## MongoDB Optimization

### Indexes (TTL + Performance)

| Collection | Index | Purpose |
|-----------|-------|---------|
| `user_activity_logs` | `{ timestamp: 1 }` TTL 30d | Auto-cleanup |
| `user_activity_logs` | `{ userId: 1, timestamp: -1 }` | User history |
| `search_analytics` | `{ timestamp: 1 }` TTL 30d | Auto-cleanup |
| `search_analytics` | `{ normalizedQuery: 1 }` | Popular searches |
| `audit_logs` | `{ timestamp: 1 }` TTL 90d | Auto-cleanup |
| `audit_logs` | `{ entityType: 1, entityId: 1 }` | Entity history |
| `order_snapshots` | `{ orderId: 1 }` unique | Lookup |
| `order_snapshots` | `{ orderDate: -1 }` | Recent orders |
| `menu_analytics` | `{ menuId: 1, period: 1 }` unique | Upsert |
| `dashboard_stats` | `{ date: 1, type: 1 }` unique | Lookup |

### Storage Management (Atlas 512 MB)

```
Cleanup priority (first cleaned when space is critical):
  1. user_activity_logs   (lowest value, highest volume)
  2. search_analytics     (can be regenerated)
  3. audit_logs           (compliance, but old ones less critical)
  4. order_snapshots      (historical, can rebuild from PostgreSQL)
  5. menu_analytics       (business insights, keep longer)
  6. dashboard_stats      (pre-computed, most valuable)
```

---

## Caching Strategy

### Application-Level (Redis / In-Memory)

| Data | TTL | Strategy |
|------|-----|----------|
| Published menus list | 1 hour | Cache-aside, invalidate on menu update |
| User sessions | 24 hours | Store in Redis, check on each request |
| Menu ratings (avg) | 5 minutes | Recompute from PostgreSQL view |
| Dashboard stats | 5 minutes | Serve from MongoDB, refresh via cron |
| Unread notification count | 30 seconds | In-memory counter, reset on read |

### CDN (Static Assets)

- Menu images: CloudFront/Cloudflare, `max-age: 86400`
- Review photos: Same CDN, `max-age: 3600`
- Static frontend: `max-age: 31536000` with content hash

---

## Real-Time Features

| Feature | Technology | Data Flow |
|---------|-----------|-----------|
| Order status updates | WebSocket (Socket.io) | PostgreSQL trigger → app event → broadcast |
| Delivery tracking | WebSocket | Employee app sends GPS → broadcast to client |
| New order notification | WebSocket | Order created → notify assigned employee |
| Kanban board sync | WebSocket | Status change → broadcast to all connected admins |
| Unread message badge | WebSocket | Message sent → increment counter → broadcast |