# CS50 SQL — Course Notes Index

## Lectures

| # | Topic | File |
|---|-------|------|
| 0 | [Querying](./Querying.md) | Introduction to databases, SELECT, WHERE, LIKE, ORDER BY, aggregates |
| 1 | [Relating](./Relating.md) | ER diagrams, keys, subqueries, JOIN, sets, GROUP BY |
| 2 | [Designing](./Designing.md) | Schema design, normalization, CREATE TABLE, constraints, ALTER TABLE |
| 3 | [Writing](./Writing.md) | INSERT, UPDATE, DELETE, triggers, soft deletions |
| 4 | [Viewing](./Viewing.md) | Views, CTEs, partitioning, securing, INSTEAD OF triggers |
| 5 | [Optimizing](./Optimizing.md) | Indexes, B-trees, VACUUM, concurrency, transactions, ACID |
| 6 | [Scaling](./Scaling.md) | MySQL, PostgreSQL, replication, sharding, access control, SQL injection |

---

## Key Concepts Applied to Vite Gourmand

| CS50 Concept | Our Implementation |
|-------------|-------------------|
| Normalization | Separate tables for users, menus, orders, reviews |
| Foreign keys | Orders reference users, order_items reference menus |
| Indexes | Composite indexes on orders(user_id, order_date) |
| Views | `v_active_menus`, `v_employee_workload`, `v_client_loyalty` |
| Triggers | Auto-track order status, auto-earn loyalty points |
| Soft deletion | `is_deleted` + `deleted_at` on users (GDPR) |
| Transactions | Order placement = insert order + items + decrement stock |
| Prepared statements | Prisma ORM parameterizes all queries |
| Access control | Role-based permissions (superadmin → client) |
