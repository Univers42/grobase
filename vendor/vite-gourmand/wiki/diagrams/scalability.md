# Scalability Strategy

---

## Current Architecture (MVP)

```
┌──────────┐     ┌──────────────┐     ┌──────────────┐
│  Vue.js  │────►│   NestJS     │────►│  PostgreSQL  │
│ Frontend │     │   Backend    │     │  (Neon/Local) │
└──────────┘     │              │     └──────────────┘
                 │              │────►┌──────────────┐
                 │              │     │   MongoDB     │
                 └──────────────┘     │  (Atlas/Local)│
                                      └──────────────┘
```

---

## Scaling PostgreSQL

### Vertical (First Step)

- Increase Neon compute units or move to dedicated instance
- Add read replicas for reporting queries
- Connection pooling via PgBouncer

### Horizontal (When Needed)

| Strategy | When | How |
|----------|------|-----|
| **Read replicas** | > 1000 concurrent users | Route analytics/reports to replica |
| **Table partitioning** | > 10M orders | Partition `orders` by `order_date` (monthly) |
| **Sharding** | > 100M rows | Shard by `user_id` or region (unlikely for this app) |

---

## Scaling MongoDB

### Atlas Free → Shared → Dedicated

| Tier | Storage | Use Case |
|------|---------|----------|
| Free (M0) | 512 MB | Development, MVP |
| Shared (M2) | 2 GB | Production, < 10K users |
| Dedicated (M10+) | 10+ GB | Production, > 10K users |

### Data Lifecycle

- TTL indexes handle automatic cleanup
- Emergency cleanup halves retention when storage > 85%
- Old analytics can be exported to S3/GCS before deletion

---

## Queue System (Future)

```
Order Created → RabbitMQ/BullMQ → 
  ├── Send confirmation email
  ├── Create MongoDB order snapshot
  ├── Update dashboard stats
  ├── Notify assigned employee (WebSocket)
  └── Update menu stock
```

---

## Monitoring

| Metric | Tool | Alert Threshold |
|--------|------|-----------------|
| API response time | Application logs | > 500ms p95 |
| PostgreSQL query time | Prisma metrics | > 100ms avg |
| MongoDB storage | Atlas monitoring | > 85% capacity |
| Error rate | Sentry / application | > 1% of requests |
| Uptime | Health check endpoint | Any downtime |
