# Vite Gourmand — Database Architecture

> Documentation hub for all database design decisions.

---

## Architecture Overview

```
┌──────────┐     ┌──────────────┐     ┌──────────────┐
│  Vue.js  │────►│   NestJS     │────►│  PostgreSQL  │  Source of truth
│ Frontend │     │   Backend    │     │  (Prisma ORM)│  Transactional data
└──────────┘     │              │     └──────────────┘
                 │              │────►┌──────────────┐
                 │              │     │   MongoDB     │  Analytics & logs
                 └──────────────┘     │  (Atlas/Local)│  Charts data (NoSQL)
                                      └──────────────┘
```

---

## Documentation Index

| Document | Purpose |
|----------|---------|
| [Analyse des besoins](./analyze_need.md) | Role hierarchy, permission matrix, business rules |
| [Cas d'utilisation](./usecase.md) | Detailed use cases by role, GDPR requirements |
| [Base relationnelle (PostgreSQL)](./relational_database.md) | ER diagram, indexes, triggers, views |
| [Base NoSQL (MongoDB)](./nosql_database.md) | Analytics collections, aggregation pipelines |
| [Sécurité](./security.md) | Authentication, GDPR procedures, checklist |
| [Optimisation](./optimization_design.md) | Indexing strategy, caching, real-time features |
| [Scalabilité](./scalability.md) | Scaling strategy, monitoring |
| [Exemples SQL](./example.md) | Trigger implementations, view definitions, index DDL |

---

## Subject Requirements Coverage

| Requirement | PostgreSQL | MongoDB | Status |
|-------------|:----------:|:-------:|:------:|
| Menus CRUD (admin + employee) | `Menu`, `Dish`, `MenuImage` | — | ✅ |
| Dishes shared across menus (M:N) | `MenuDishes` junction | — | ✅ |
| 14 EU allergens per dish | `DishAllergen` junction | — | ✅ |
| Menu conditions (lead time) | `Menu.conditions` | — | ✅ |
| Menu filters (price, theme, diet, persons) | Indexed columns | — | ✅ |
| Menu stock management | `Menu.remaining_qty` | — | ✅ |
| Order with delivery pricing | `Order.delivery_*` fields | `OrderSnapshot` | ✅ |
| 10% discount (person_min + 5) | `Order.discount_*` fields | — | ✅ |
| Order status lifecycle (8 statuses) | `Order.status` + `OrderStatusHistory` | `OrderSnapshot.status` | ✅ |
| Material lending + return deadline | `Order.material_*` fields | — | ✅ |
| Employee cancel with reason + contact mode | `Order.cancellation_*` fields | `AuditLog` | ✅ |
| Client cancel/modify before accepted | Backend guards on status | — | ✅ |
| Reviews linked to orders (1-5 stars) | `Publish` model | — | ✅ |
| Review moderation (approve/reject) | `Publish.status` | — | ✅ |
| Contact form (title + desc + email) | `ContactMessage` | — | ✅ |
| Working hours Mon-Sun (footer) | `WorkingHours` | — | ✅ |
| Admin: orders per menu chart | — | `MenuAnalytics` | ✅ |
| Admin: CA par menu with filters | — | `RevenueByMenu` | ✅ |
| Admin: create employee accounts | `User` + `Role` | — | ✅ |
| Admin: disable employee accounts | `User.is_active` | — | ✅ |
| Admin account seeded (José) | Seed script | — | ✅ |
| Password reset via email link | `PasswordResetToken` | — | ✅ |
| RGPD consent tracking | `UserConsent`, `gdprConsent` | — | ✅ |
| RGAA accessibility | Frontend concern | — | 🔧 |

---

## Conclusion

This architecture provides:

✅ **Subject compliance**: Every requirement from the Studi brief is covered  
✅ **Scalability**: Indexes, caching, MongoDB for analytics  
✅ **GDPR**: Consent tracking, soft deletion, data export  
✅ **Security**: Bcrypt, parameterized queries, role-based access  
✅ **Extensibility**: Modular design for future features (loyalty, messaging, kanban)